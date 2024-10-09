#include <stdint.h>

#pragma once

typedef int64_t clock_t;
typedef clock_t time_t;

clock_t clock();

// struct tm {
// 	int tm_sec;
// 	int tm_min;
// 	int tm_hour;
// 	int tm_mday;
// 	int tm_mon;
// 	int tm_year;
// 	int tm_wday;
// 	int tm_yday;
// 	int tm_isdst;
// };
//
// struct timespec {
// 	time_t tv_sec;
// 	long tv_nsec;
// };
//
// #define TIME_UTC 0
//
// int timespec_get(struct timespec *ts, int base);
// time_t time(time_t *);
// tm* localtime(const time_t *);
