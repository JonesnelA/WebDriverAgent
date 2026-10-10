#include <stdint.h>
#include <stddef.h>
typedef struct Engine Engine;
Engine *tb_open(const char *path, int32_t media);
int32_t tb_touch(Engine *engine, uint32_t phase, double x, double y, uint32_t orientation);
uint8_t *tb_screenshot(Engine *engine, size_t *length);
void tb_data_free(uint8_t *data, size_t length);
char *tb_last_error(void);
void tb_string_free(char *text);
void tb_close(Engine *engine);
