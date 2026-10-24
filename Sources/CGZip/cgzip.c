#include "CGZip.h"

#include <stdlib.h>
#include <string.h>
#include <zlib.h>

void voxtype_free(void *ptr) {
    free(ptr);
}

int voxtype_gzip_compress(const uint8_t *src, size_t src_len, uint8_t **dst, size_t *dst_len) {
    uint8_t dummy = 0;
    z_stream stream;
    uLong bound;
    uint8_t *out;
    int ret;

    if (dst == NULL || dst_len == NULL) {
        return -1;
    }
    if (src == NULL) {
        src = &dummy;
        src_len = 0;
    }
    bound = compressBound((uLong)src_len) + 64;
    out = (uint8_t *)malloc(bound);
    if (out == NULL) {
        return -1;
    }
    memset(&stream, 0, sizeof(stream));
    if (deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY) != Z_OK) {
        free(out);
        return -1;
    }
    stream.next_in = (Bytef *)src;
    stream.avail_in = (uInt)src_len;
    stream.next_out = out;
    stream.avail_out = (uInt)bound;
    ret = deflate(&stream, Z_FINISH);
    deflateEnd(&stream);
    if (ret != Z_STREAM_END) {
        free(out);
        return -1;
    }
    *dst = out;
    *dst_len = (size_t)stream.total_out;
    return 0;
}

int voxtype_gzip_decompress(const uint8_t *src, size_t src_len, uint8_t **dst, size_t *dst_len) {
    z_stream stream;
    size_t capacity;
    uint8_t *out;
    int ret;

    if (src == NULL || dst == NULL || dst_len == NULL || src_len == 0) {
        return -1;
    }
    capacity = src_len * 4;
    if (capacity < 64) {
        capacity = 64;
    }
    out = (uint8_t *)malloc(capacity);
    if (out == NULL) {
        return -1;
    }
    memset(&stream, 0, sizeof(stream));
    if (inflateInit2(&stream, 15 + 16) != Z_OK) {
        free(out);
        return -1;
    }
    stream.next_in = (Bytef *)src;
    stream.avail_in = (uInt)src_len;
    for (;;) {
        if (stream.total_out >= capacity) {
            size_t grown = capacity * 2;
            uint8_t *next = (uint8_t *)realloc(out, grown);
            if (next == NULL) {
                inflateEnd(&stream);
                free(out);
                return -1;
            }
            out = next;
            capacity = grown;
        }
        stream.next_out = out + stream.total_out;
        stream.avail_out = (uInt)(capacity - stream.total_out);
        ret = inflate(&stream, Z_NO_FLUSH);
        if (ret == Z_STREAM_END) {
            break;
        }
        if (ret != Z_OK) {
            inflateEnd(&stream);
            free(out);
            return -1;
        }
    }
    inflateEnd(&stream);
    *dst = out;
    *dst_len = (size_t)stream.total_out;
    return 0;
}
