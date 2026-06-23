/* Used for ProcessList.zig to read list of processes on Windows */

#define WIN32_LEAN_AND_MEAN 1
#define _WIN32_WINNT 0x0400
#define _WIN32_DCOM 1

#include <wbemcli.h>
