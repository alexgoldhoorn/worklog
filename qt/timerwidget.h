#pragma once

#include <QObject>
#include <QString>
#include <QtQml/qqmlregistration.h>

// Android: keeps the home-screen widget, the Quick Settings tile and the ongoing notification
// (android/src/.../TimerWidget.java, TimerTile.java) in step with the app. They call the server
// themselves, so they need its URL and user (mirrored into SharedPreferences here; the password is read
// from SecretStore) and a nudge after the app's own timer actions. Elsewhere it does nothing.
class TimerWidget : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    explicit TimerWidget(QObject *parent = nullptr);

    Q_INVOKABLE void configure(const QString &url, const QString &user);
    // fetches the status again and redraws the widget, tile and notification
    Q_INVOKABLE void refresh();
};
