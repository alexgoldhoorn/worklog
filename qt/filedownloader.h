#pragma once

#include <QNetworkAccessManager>
#include <QObject>
#include <QUrl>
#include <QtQml/qqmlregistration.h>

// Downloads a URL straight to a local file (QML's XMLHttpRequest cannot write files).
class FileDownloader : public QObject
{
    Q_OBJECT
    QML_ELEMENT

public:
    explicit FileDownloader(QObject *parent = nullptr);

    // `authorization` is sent as the Authorization header when not empty
    Q_INVOKABLE void download(const QString &url, const QString &authorization, const QUrl &target);

signals:
    void finished(const QString &path);
    void failed(const QString &message);

private:
    QNetworkAccessManager m_net;
};
