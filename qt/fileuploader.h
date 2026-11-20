#pragma once

#include <QNetworkAccessManager>
#include <QObject>
#include <QUrl>
#include <QtQml/qqmlregistration.h>

// Uploads one local file as a multipart form (QML's XMLHttpRequest cannot read a file, nor a content://
// document Android's file picker hands out). The counterpart of FileDownloader.
class FileUploader : public QObject
{
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)

public:
    explicit FileUploader(QObject *parent = nullptr);

    bool busy() const { return m_busy; }

    // POSTs `source` (a file:// or content:// URL) as the form field `field` to `url`.
    // `authorization` is sent as the Authorization header when not empty. `maxBytes` > 0 refuses a bigger file
    // before it is read. `finished` carries the server's JSON answer; an error comes back as `failed`
    // with the server's {"error": "..."} text when it sent one.
    Q_INVOKABLE void upload(const QString &url, const QString &authorization, const QUrl &source,
                            const QString &field, qint64 maxBytes = 0);

    // The file name to send for a picked file: its own name when it is a plain .pdf-like name, else `fallback`
    // (a content:// URL does not always carry one). Public so the tests can call it.
    Q_INVOKABLE static QString uploadName(const QUrl &source, const QString &fallback);

signals:
    void busyChanged();
    void finished(const QVariant &answer);
    void failed(const QString &message);

private:
    void fail(const QString &message);

    QNetworkAccessManager m_net;
    bool m_busy = false;
};
