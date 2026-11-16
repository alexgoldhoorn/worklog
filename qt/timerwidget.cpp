#include "timerwidget.h"

#ifdef Q_OS_ANDROID
#include <QCoreApplication>
#include <QJniObject>

static const char *clientClass = "net/goldhoorn/worklog/WorklogClient";
static const char *widgetClass = "net/goldhoorn/worklog/TimerWidget";

TimerWidget::TimerWidget(QObject *parent) : QObject(parent) {}

void TimerWidget::configure(const QString &url, const QString &user)
{
    QJniObject::callStaticMethod<void>(clientClass, "configure",
                                       "(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)V",
                                       QNativeInterface::QAndroidApplication::context().object(),
                                       QJniObject::fromString(url).object<jstring>(),
                                       QJniObject::fromString(user).object<jstring>());
    // the ongoing notification needs it on Android 13+ (asked once; a no-op once answered for good)
    if (!url.isEmpty())
        QJniObject::callStaticMethod<void>("net/goldhoorn/worklog/PomodoroAlarm", "requestPermission",
                                           "(Landroid/app/Activity;)V",
                                           QNativeInterface::QAndroidApplication::context().object());
}

void TimerWidget::refresh()
{
    QJniObject::callStaticMethod<void>(widgetClass, "refresh", "(Landroid/content/Context;)V",
                                       QNativeInterface::QAndroidApplication::context().object());
}

#else

TimerWidget::TimerWidget(QObject *parent) : QObject(parent) {}
void TimerWidget::configure(const QString &, const QString &) {}
void TimerWidget::refresh() {}

#endif
