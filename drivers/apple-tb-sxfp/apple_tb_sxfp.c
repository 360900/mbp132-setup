// SPDX-License-Identifier: GPL-2.0
/*
 * apple_tb_sxfp: keep USB-C devices working across S3 on 2016-2017 MacBook
 * Pros with Intel Alpine Ridge Thunderbolt controllers.
 *
 * In S3 the firmware cuts power to the controllers. If a device is plugged
 * in, the link to the controller does not come back on resume and the ports
 * are lost until reboot. macOS avoids that by cutting the power itself first,
 * with the SXFP(0) ACPI method under the NHI. This module does the same, at
 * the point the unmerged kernel patch "thunderbolt: Call SXFP() on Apple
 * systems with Alpine Ridge when suspending" (Francisco Beltrán Millalén)
 * uses: just before the thunderbolt driver suspends the domain. Bit 26 of plug
 * events CS_20 is cleared first through the firmware's own UPSB.CRMW, because
 * with it set the router does not come back.
 *
 * The controller's config space is saved in suspend_late, while it is still
 * readable, and restored in resume_noirq, parents first. This and the
 * dev_pm_domain approach come from tb_ar_shim by Andrew Clunis
 * (https://github.com/orospakr/linux-apple-alpine-ridge-suspend, GPL-2.0).
 *
 * If the suspend is aborted after SXFP(0), the firmware does not power the
 * controller on again; the root port's UGIO does, as on macOS.
 *
 * Loads before the thunderbolt driver (modprobe softdep), so no bound driver
 * has to be detached.
 */
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/acpi.h>
#include <linux/pm_domain.h>
#include <linux/pm_runtime.h>
#include <linux/delay.h>
#include <linux/suspend.h>
#include <linux/platform_data/x86/apple.h>

#define MAX_CTRL		2
#define BRIDGE_WAIT_MS		3000
#define SUBTREE_WAIT_MS		200
#define PCI_DEVICE_ID_AR_UPSB	0x1578	/* Alpine Ridge upstream port */
#define PCI_DEVICE_ID_AR_NHI	0x15d2	/* Alpine Ridge 4C NHI (C step) */

struct ctrl {
	struct pci_dev *upsb;
	struct pci_dev *nhi;
	bool cut;
};

static struct ctrl ctrls[MAX_CTRL];
static int nctrl;
static const struct dev_pm_ops *bus_pm;
static struct dev_pm_domain upsb_pd, nhi_pd;

static struct ctrl *ctrl_of(struct pci_dev *pdev)
{
	int i;

	for (i = 0; i < nctrl; i++)
		if (ctrls[i].upsb == pdev || ctrls[i].nhi == pdev)
			return &ctrls[i];
	return NULL;
}

static int save_cb(struct pci_dev *dev, void *data)
{
	u32 id;

	pci_read_config_dword(dev, PCI_VENDOR_ID, &id);
	if (id == 0xffffffff) {
		pci_warn(dev, "apple_tb_sxfp: not readable, config not saved\n");
		return 0;
	}
	if (dev->class == PCI_CLASS_SERIAL_USB_XHCI) {
		/* A runtime suspended xHCI was saved by the PCI core already. */
		if (dev->current_state != PCI_D0)
			return 0;
		pci_save_state(dev);
		pci_prepare_to_sleep(dev);
		return 0;
	}
	pci_save_state(dev);
	return 0;
}

static int upsb_suspend_late(struct device *dev)
{
	struct pci_dev *pdev = to_pci_dev(dev);
	int ret = bus_pm->suspend_late ? bus_pm->suspend_late(dev) : 0;

	if (ret)
		return ret;
	save_cb(pdev, NULL);
	if (pdev->subordinate)
		pci_walk_bus(pdev->subordinate, save_cb, NULL);
	return 0;
}

/* UPSB.CRMW(0x3c, port 0, switch space, value 0, mask bit 26) */
static int clear_bit26(acpi_handle upsb)
{
	union acpi_object a[5] = {
		{ .integer = { ACPI_TYPE_INTEGER, 0x3c } },
		{ .integer = { ACPI_TYPE_INTEGER, 0 } },
		{ .integer = { ACPI_TYPE_INTEGER, 2 } },
		{ .integer = { ACPI_TYPE_INTEGER, 0 } },
		{ .integer = { ACPI_TYPE_INTEGER, 0x04000000 } },
	};
	struct acpi_object_list args = { ARRAY_SIZE(a), a };
	unsigned long long r = 1;

	if (ACPI_FAILURE(acpi_evaluate_integer(upsb, "CRMW", &args, &r)))
		return -EIO;
	return r ? -EIO : 0;
}

static int nhi_suspend_noirq(struct device *dev)
{
	struct pci_dev *pdev = to_pci_dev(dev);
	struct ctrl *c = ctrl_of(pdev);

	if (c && pm_suspend_via_firmware()) {
		if (clear_bit26(ACPI_HANDLE(&c->upsb->dev)))
			pci_warn(pdev, "apple_tb_sxfp: could not clear bit 26, power not cut\n");
		else if (ACPI_FAILURE(acpi_execute_simple_method(ACPI_HANDLE(dev), "SXFP", 0)))
			pci_warn(pdev, "apple_tb_sxfp: SXFP failed\n");
		else
			c->cut = true;
	}
	return bus_pm->suspend_noirq ? bus_pm->suspend_noirq(dev) : 0;
}

static int restore_cb(struct pci_dev *dev, void *data)
{
	int *budget = data;
	u32 id;

	for (;;) {
		pci_read_config_dword(dev, PCI_VENDOR_ID, &id);
		if (id != 0xffffffff && id != 0)
			break;
		if (*budget <= 0) {
			pci_warn(dev, "apple_tb_sxfp: not readable after resume\n");
			return 0;
		}
		msleep(10);
		*budget -= 10;
	}
	if (dev->state_saved)
		pci_restore_state(dev);
	return 0;
}

static int upsb_resume_noirq(struct device *dev)
{
	struct pci_dev *pdev = to_pci_dev(dev);
	struct ctrl *c = ctrl_of(pdev);
	int budget = SUBTREE_WAIT_MS, waited = 0, ret;
	unsigned long long on = 0;
	u32 id;

	/* Powers the controller on after an aborted suspend; a no-op after S3. */
	if (c && c->cut) {
		c->cut = false;
		if (ACPI_FAILURE(acpi_evaluate_integer(ACPI_HANDLE(&pdev->bus->self->dev),
						       "UGIO", NULL, &on)))
			pci_warn(pdev, "apple_tb_sxfp: UGIO failed\n");
		else if (on)
			pci_info(pdev, "apple_tb_sxfp: powered on again\n");
	}
	for (;;) {
		pci_read_config_dword(pdev, PCI_VENDOR_ID, &id);
		if (id != 0xffffffff && id != 0)
			break;
		if (waited >= BRIDGE_WAIT_MS) {
			pci_err(pdev, "apple_tb_sxfp: not readable %d ms after resume\n", waited);
			break;
		}
		msleep(10);
		waited += 10;
	}
	ret = bus_pm->resume_noirq ? bus_pm->resume_noirq(dev) : 0;
	if (ret)
		return ret;
	if (pdev->state_saved)
		pci_restore_state(pdev);
	if (pdev->subordinate)
		pci_walk_bus(pdev->subordinate, restore_cb, &budget);
	return 0;
}

static int nhi_cb(struct pci_dev *dev, void *data)
{
	struct pci_dev **nhi = data;

	if (dev->vendor == PCI_VENDOR_ID_INTEL && dev->device == PCI_DEVICE_ID_AR_NHI) {
		*nhi = pci_dev_get(dev);
		return 1;
	}
	return 0;
}

/* The firmware methods this module calls, on the on-board controllers only. */
static bool has_methods(struct pci_dev *upsb, struct pci_dev *nhi)
{
	acpi_handle u = ACPI_HANDLE(&upsb->dev), n = ACPI_HANDLE(&nhi->dev);
	acpi_handle rp = upsb->bus->self ? ACPI_HANDLE(&upsb->bus->self->dev) : NULL;

	return u && n && rp && acpi_has_method(u, "CRMW") &&
	       acpi_has_method(n, "SXFP") && acpi_has_method(rp, "UGIO");
}

static void attach(struct pci_dev *pdev, struct dev_pm_domain *pd)
{
	device_release_driver(&pdev->dev);
	dev_pm_domain_set(&pdev->dev, pd);
	if (device_attach(&pdev->dev) < 0)
		pci_warn(pdev, "apple_tb_sxfp: device_attach failed\n");
}

static int __init apple_tb_sxfp_init(void)
{
	struct pci_dev *upsb = NULL, *nhi;
	int i;

	if (!x86_apple_machine)
		return -ENODEV;
	while (nctrl < MAX_CTRL &&
	       (upsb = pci_get_device(PCI_VENDOR_ID_INTEL, PCI_DEVICE_ID_AR_UPSB, upsb))) {
		nhi = NULL;
		if (upsb->subordinate)
			pci_walk_bus(upsb->subordinate, nhi_cb, &nhi);
		if (!nhi)
			continue;
		if (!has_methods(upsb, nhi)) {
			pci_dev_put(nhi);
			continue;
		}
		ctrls[nctrl].upsb = pci_dev_get(upsb);
		ctrls[nctrl].nhi = nhi;
		nctrl++;
	}
	pci_dev_put(upsb);
	if (!nctrl)
		return -ENODEV;

	bus_pm = ctrls[0].upsb->dev.bus->pm;
	upsb_pd.ops = *bus_pm;
	upsb_pd.ops.suspend_late = upsb_suspend_late;
	upsb_pd.ops.resume_noirq = upsb_resume_noirq;
	nhi_pd.ops = *bus_pm;
	nhi_pd.ops.suspend_noirq = nhi_suspend_noirq;
	for (i = 0; i < nctrl; i++) {
		attach(ctrls[i].upsb, &upsb_pd);
		/* A runtime suspended NHI could skip suspend_noirq. */
		pm_runtime_forbid(&ctrls[i].nhi->dev);
		attach(ctrls[i].nhi, &nhi_pd);
		pci_info(ctrls[i].upsb, "apple_tb_sxfp: installed\n");
	}
	return 0;
}

static void __exit apple_tb_sxfp_exit(void)
{
	int i;

	for (i = 0; i < nctrl; i++) {
		attach(ctrls[i].nhi, NULL);
		pm_runtime_allow(&ctrls[i].nhi->dev);
		attach(ctrls[i].upsb, NULL);
		pci_dev_put(ctrls[i].nhi);
		pci_dev_put(ctrls[i].upsb);
	}
}

module_init(apple_tb_sxfp_init);
module_exit(apple_tb_sxfp_exit);
MODULE_LICENSE("GPL");
MODULE_VERSION("0.1");
MODULE_DESCRIPTION("Apple Alpine Ridge Thunderbolt: cut power before S3 as macOS does");
