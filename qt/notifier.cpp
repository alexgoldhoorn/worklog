#include "notifier.h"

#ifdef Q_OS_ANDROID
#include <QCoreApplication>
#include <QJniObject>

static const char *alarmClass = "net/goldhoorn/worklog/PomodoroAlarm";

Notifier::Notifier(QObject *parent) : QObject(parent)
{
    QJniObject::callStaticMethod<void>(alarmClass, "requestPermission", "(Landroid/app/Activity;)V",
                                       QNativeInterface::QAndroidApplication::context().object());
}

void Notifier::schedule(qint64 atMs, const QString &title, const QString &text)
{
    QJniObject::callStaticMethod<void>(alarmClass, "schedule",
                                       "(Landroid/content/Context;JLjava/lang/String;Ljava/lang/String;)V",
                                       QNativeInterface::QAndroidApplication::context().object(), jlong(atMs),
                                       QJniObject::fromString(title).object<jstring>(),
                                       QJniObject::fromString(text).object<jstring>());
}

void Notifier::cancel()
{
    QJniObject::callStaticMethod<void>(alarmClass, "cancel", "(Landroid/content/Context;)V",
                                       QNativeInterface::QAndroidApplication::context().object());
}

#else

Notifier::Notifier(QObject *parent) : QObject(parent) {}
void Notifier::schedule(qint64, const QString &, const QString &) {}
void Notifier::cancel() {}

#endif
