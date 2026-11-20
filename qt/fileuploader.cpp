#include "fileuploader.h"

#include <QFile>
#include <QHttpMultiPart>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkReply>
#include <QNetworkRequest>

FileUploader::FileUploader(QObject *parent)
    : QObject(parent)
{}

QString FileUploader::uploadName(const QUrl &source, const QString &fallback)
{
    // file:///C:/x/Calendar.pdf -> Calendar.pdf; content://…/document/primary%3AX%2FCalendar.pdf -> Calendar.pdf
    QString path = source.isLocalFile() ? source.toLocalFile() : source.path(QUrl::FullyDecoded);
    path.replace(QLatin1Char('\\'), QLatin1Char('/'));
    QString name = path.mid(path.lastIndexOf(QLatin1Char('/')) + 1);
    name = name.mid(name.lastIndexOf(QLatin1Char(':')) + 1);
    if (name.isEmpty() || name.size() > 120 || !name.endsWith(QLatin1String(".pdf"), Qt::CaseInsensitive))
        return fallback;
    return name;
}

void FileUploader::fail(const QString &message)
{
    m_busy = false;
    emit busyChanged();
    emit failed(message);
}

void FileUploader::upload(const QString &url, const QString &authorization, const QUrl &source,
                          const QString &field, qint64 maxBytes)
{
    if (m_busy)
        return;
    m_busy = true;
    emit busyChanged();

    // Qt opens a content:// document through the same QFile, given the URL as the path
    const QString path = source.isLocalFile() ? source.toLocalFile() : source.toString();
    auto *file = new QFile(path);
    if (!file->open(QIODevice::ReadOnly)) {
        const QString why = file->errorString();
        delete file;
        fail(tr("Cannot read the file: %1").arg(why));
        return;
    }
    if (maxBytes > 0 && file->size() > maxBytes) {
        delete file;
        fail(tr("File too large (%1 MB max)").arg(maxBytes / (1024 * 1024)));
        return;
    }

    auto *multi = new QHttpMultiPart(QHttpMultiPart::FormDataType);
    QHttpPart part;
    const QString name = uploadName(source, QStringLiteral("calendar.pdf"));
    part.setHeader(QNetworkRequest::ContentDispositionHeader,
                   QStringLiteral("form-data; name=\"%1\"; filename=\"%2\"").arg(field, name));
    part.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/pdf"));
    part.setBodyDevice(file);
    file->setParent(multi);   // closed and deleted with the multipart
    multi->append(part);

    QNetworkRequest request{QUrl(url)};
    if (!authorization.isEmpty())
        request.setRawHeader("Authorization", authorization.toUtf8());

    QNetworkReply *reply = m_net.post(request, multi);
    multi->setParent(reply);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        const QByteArray body = reply->readAll();
        const QJsonObject json = QJsonDocument::fromJson(body).object();
        if (reply->error() != QNetworkReply::NoError) {
            const QString serverError = json.value("error").toString();
            fail(serverError.isEmpty() ? reply->errorString() : serverError);
            return;
        }
        m_busy = false;
        emit busyChanged();
        emit finished(json.toVariantMap());
    });
}
