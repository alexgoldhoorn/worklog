#include "filedownloader.h"

#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkReply>
#include <QNetworkRequest>

FileDownloader::FileDownloader(QObject *parent)
    : QObject(parent)
{}

void FileDownloader::download(const QString &url, const QString &authorization, const QUrl &target)
{
    QNetworkRequest request{QUrl(url)};
    if (!authorization.isEmpty())
        request.setRawHeader("Authorization", authorization.toUtf8());

    QNetworkReply *reply = m_net.get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, target]() {
        reply->deleteLater();
        const QByteArray body = reply->readAll();
        if (reply->error() != QNetworkReply::NoError) {
            // the server answers errors as {"error": "..."}
            const QString serverError = QJsonDocument::fromJson(body).object().value("error").toString();
            emit failed(serverError.isEmpty() ? reply->errorString() : serverError);
            return;
        }
        const QString path = target.isLocalFile() ? target.toLocalFile() : target.toString();
        QFile file(path);
        if (!file.open(QIODevice::WriteOnly) || file.write(body) != body.size()) {
            emit failed(tr("Cannot write %1: %2").arg(path, file.errorString()));
            return;
        }
        emit finished(path);
    });
}
