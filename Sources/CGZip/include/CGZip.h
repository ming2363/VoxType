#ifndef CGZIP_H
#define CGZIP_H

#include <stddef.h>
#include <stdint.h>

int voxtype_gzip_compress(const uint8_t *src, size_t src_len, uint8_t **dst, size_t *dst_len);
int voxtype_gzip_decompress(const uint8_t *src, size_t src_len, uint8_t **dst, size_t *dst_len);
void voxtype_free(void *ptr);

#endif
