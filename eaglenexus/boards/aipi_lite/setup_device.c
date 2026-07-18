/*
 * Board-specific device setup for the Xorigin AiPi Lite.
 *
 * ESP-Claw has no built-in ST7735 panel driver, so the display device in
 * board_devices.yaml declares chip "st7735" and the board manager resolves
 * the panel through this factory, backed by the teriyakigod/esp_lcd_st7735
 * registry component.
 */

#include <string.h>
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_st7735.h"
#include "esp_log.h"

/*
 * The 1.44" 128x128 glass sits inside the ST7735S 132x162 frame RAM.
 * Typical "green tab" offsets are x=2, y=3; if the image is shifted or
 * shows noise rows along an edge, try 0/0 or 2/1.
 */
#define AIPI_LCD_GAP_X 2
#define AIPI_LCD_GAP_Y 3

static const char *TAG = "AIPI_SETUP_DEVICE";

esp_err_t lcd_panel_factory_entry_t(esp_lcd_panel_io_handle_t io, const esp_lcd_panel_dev_config_t *panel_dev_config, esp_lcd_panel_handle_t *ret_panel)
{
    esp_lcd_panel_dev_config_t panel_dev_cfg = {0};
    memcpy(&panel_dev_cfg, panel_dev_config, sizeof(esp_lcd_panel_dev_config_t));

    esp_err_t ret = esp_lcd_new_panel_st7735(io, &panel_dev_cfg, ret_panel);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "New ST7735 panel failed: %s", esp_err_to_name(ret));
        return ret;
    }

    ret = esp_lcd_panel_set_gap(*ret_panel, AIPI_LCD_GAP_X, AIPI_LCD_GAP_Y);
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "esp_lcd_panel_set_gap failed: %s", esp_err_to_name(ret));
    }

    return ESP_OK;
}
