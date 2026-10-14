// Powłoka nad systemowym libcurl (libcurl.4.dylib w macOS). `curl_easy_setopt` i `curl_easy_getinfo` są wariadyczne,
// więc Swift ich nie widzi — te funkcje inline przekazują wartości o konkretnych typach.
#ifndef OC_CCURL_SHIM_H
#define OC_CCURL_SHIM_H
#include <curl/curl.h>

static inline CURLcode oc_setopt_long(CURL *h, CURLoption o, long v) { return curl_easy_setopt(h, o, v); }
static inline CURLcode oc_setopt_off(CURL *h, CURLoption o, curl_off_t v) { return curl_easy_setopt(h, o, v); }
static inline CURLcode oc_setopt_str(CURL *h, CURLoption o, const char *v) { return curl_easy_setopt(h, o, v); }
static inline CURLcode oc_setopt_ptr(CURL *h, CURLoption o, void *v) { return curl_easy_setopt(h, o, v); }
static inline CURLcode oc_setopt_slist(CURL *h, CURLoption o, struct curl_slist *v) { return curl_easy_setopt(h, o, v); }
static inline CURLcode oc_getinfo_long(CURL *h, CURLINFO i, long *out) { return curl_easy_getinfo(h, i, out); }
static inline CURLcode oc_getinfo_off(CURL *h, CURLINFO i, curl_off_t *out) { return curl_easy_getinfo(h, i, out); }

typedef size_t (*oc_data_cb)(char *ptr, size_t size, size_t nmemb, void *userdata);
typedef int (*oc_xfer_cb)(void *clientp, curl_off_t dltotal, curl_off_t dlnow, curl_off_t ultotal, curl_off_t ulnow);
typedef int (*oc_debug_cb)(CURL *handle, curl_infotype type, char *data, size_t size, void *userptr);

static inline CURLcode oc_set_write_cb(CURL *h, oc_data_cb cb, void *ud) {
    CURLcode r = curl_easy_setopt(h, CURLOPT_WRITEFUNCTION, cb);
    return r != CURLE_OK ? r : curl_easy_setopt(h, CURLOPT_WRITEDATA, ud);
}
static inline CURLcode oc_set_read_cb(CURL *h, oc_data_cb cb, void *ud) {
    CURLcode r = curl_easy_setopt(h, CURLOPT_READFUNCTION, cb);
    return r != CURLE_OK ? r : curl_easy_setopt(h, CURLOPT_READDATA, ud);
}
static inline CURLcode oc_set_xfer_cb(CURL *h, oc_xfer_cb cb, void *ud) {
    CURLcode r = curl_easy_setopt(h, CURLOPT_XFERINFOFUNCTION, cb);
    return r != CURLE_OK ? r : curl_easy_setopt(h, CURLOPT_XFERINFODATA, ud);
}
static inline CURLcode oc_set_debug_cb(CURL *h, oc_debug_cb cb, void *ud) {
    CURLcode r = curl_easy_setopt(h, CURLOPT_DEBUGFUNCTION, cb);
    return r != CURLE_OK ? r : curl_easy_setopt(h, CURLOPT_DEBUGDATA, ud);
}
#endif
