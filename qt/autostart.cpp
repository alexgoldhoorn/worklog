#include "autostart.h"

#include <QCoreApplication>
#include <QDir>
#include <QSettings>

static const char *kRunKey = "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Run";

Autostart::Autostart(QObject *parent) : QObject(parent)
{
    // The Run entry is only ever written by setEnabled(): a build-directory exe must not repoint it.
    refresh();
}

bool Autostart::startMinimized() const
{
    return QCoreApplication::arguments().contains(QStringLiteral("--minimized"));
}

void Autostart::setError(const QString &e)
{
    if (e == m_error)
        return;
    m_error = e;
    emit errorChanged();
}

#ifdef Q_OS_WIN

bool Autostart::supported() const { return true; }

QString Autostart::valueName() const
{
    // a scratch copy (WORKLOG_ORG, see main.cpp) gets its own entry, never the real one
    const QString org = QCoreApplication::organizationName();
    const QString app = QCoreApplication::applicationName();
    return org == QLatin1String("worklog") ? app : app + QLatin1Char('-') + org;
}

QString Autostart::command() const
{
    return QStringLiteral("\"%1\" --minimized")
        .arg(QDir::toNativeSeparators(QCoreApplication::applicationFilePath()));
}

void Autostart::refresh()
{
    QSettings run(kRunKey, QSettings::NativeFormat);
    const bool on = run.contains(valueName());
    if (on != m_enabled) {
        m_enabled = on;
        emit enabledChanged();
    }
}

void Autostart::setEnabled(bool on)
{
    QSettings run(kRunKey, QSettings::NativeFormat);
    if (on)
        run.setValue(valueName(), command());
    else
        run.remove(valueName());
    run.sync();
    const bool failed = run.status() != QSettings::NoError;
    refresh();
    setError(failed || m_enabled != on ? tr("Could not change the Windows start-up entry") : QString());
    emit enabledChanged();   // lets a Switch snap back to the real state after a failure
}

#else

bool Autostart::supported() const { return false; }
QString Autostart::valueName() const { return {}; }
QString Autostart::command() const { return {}; }
void Autostart::refresh() {}
void Autostart::setEnabled(bool) {}

#endif
