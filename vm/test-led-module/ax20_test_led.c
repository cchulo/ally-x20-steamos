// SPDX-License-Identifier: GPL-2.0-only
/*
 * ax20_test_led — VM-only test module for ally-x20-steamos (plan §6 check 6).
 *
 * Registers a multicolor LED class device named "go_s:rgb:joystick_rings"
 * with three single-colour subleds (red, green, blue), which is the shape
 * our patched hid-asus-ally exposes on the X20. The Steam client discovers
 * joystick-ring RGB only through a few hard-coded LED names, so loading
 * this module in the VM lets us check that Steam's Customization section
 * appears and writes multi_intensity/brightness, without any ASUS hardware.
 *
 * Never load this on a real device: it would shadow the real LED name.
 */
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/led-class-multicolor.h>

#define AX20_TEST_LED_NAME "go_s:rgb:joystick_rings"

static struct platform_device *ax20_pdev;

static struct mc_subled ax20_subleds[3] = {
	{ .color_index = LED_COLOR_ID_RED, .channel = 0, .intensity = 255 },
	{ .color_index = LED_COLOR_ID_GREEN, .channel = 1, .intensity = 255 },
	{ .color_index = LED_COLOR_ID_BLUE, .channel = 2, .intensity = 255 },
};

static int ax20_led_set(struct led_classdev *cdev, enum led_brightness value)
{
	struct led_classdev_mc *mc = lcdev_to_mccdev(cdev);

	led_mc_calc_color_components(mc, value);
	/* Visible with dyndbg or in dmesg at debug level: proves Steam wrote us. */
	pr_info("ax20_test_led: brightness=%u rgb=%u,%u,%u\n", value,
		mc->subled_info[0].brightness, mc->subled_info[1].brightness,
		mc->subled_info[2].brightness);
	return 0;
}

static struct led_classdev_mc ax20_mc = {
	.led_cdev = {
		.name = AX20_TEST_LED_NAME,
		.max_brightness = 255,
		.brightness = 255,
		.brightness_set_blocking = ax20_led_set,
	},
	.num_colors = ARRAY_SIZE(ax20_subleds),
	.subled_info = ax20_subleds,
};

static int __init ax20_test_led_init(void)
{
	int ret;

	ax20_pdev = platform_device_register_simple("ax20_test_led", -1, NULL, 0);
	if (IS_ERR(ax20_pdev))
		return PTR_ERR(ax20_pdev);

	ret = led_classdev_multicolor_register(&ax20_pdev->dev, &ax20_mc);
	if (ret) {
		platform_device_unregister(ax20_pdev);
		return ret;
	}
	pr_info("ax20_test_led: registered %s\n", AX20_TEST_LED_NAME);
	return 0;
}

static void __exit ax20_test_led_exit(void)
{
	led_classdev_multicolor_unregister(&ax20_mc);
	platform_device_unregister(ax20_pdev);
}

module_init(ax20_test_led_init);
module_exit(ax20_test_led_exit);

MODULE_AUTHOR("ally-x20-steamos");
MODULE_DESCRIPTION("VM-only fake go_s:rgb:joystick_rings multicolor LED for Steam discovery tests");
MODULE_LICENSE("GPL");
