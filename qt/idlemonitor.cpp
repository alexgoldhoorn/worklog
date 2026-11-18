#include "idlemonitor.h"

#ifdef Q_OS_WIN
#include <windows.h>

bool IdleMonitor::available() const { return true; }

double IdleMonitor::idleSeconds() const
{
    LASTINPUTINFO li;
    li.cbSize = sizeof(li);
    if (!GetLastInputInfo(&li))
        return 0;
    const DWORD ms = GetTickCount() - li.dwTime;   // unsigned: survives the 49-day wrap
    return ms / 1000.0;
}
#else
bool IdleMonitor::available() const { return false; }
double IdleMonitor::idleSeconds() const { return 0; }
#endif
