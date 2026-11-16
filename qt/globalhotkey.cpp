#include "globalhotkey.h"

#include <QCoreApplication>
#include <QKeySequence>

#ifdef Q_OS_WIN
#include <windows.h>
#endif

GlobalHotkey::GlobalHotkey(QObject *parent) : QObject(parent) {}

GlobalHotkey::~GlobalHotkey()
{
    release();
}

void GlobalHotkey::setSequence(const QString &s)
{
    if (s == m_sequence)
        return;
    m_sequence = s;
    emit sequenceChanged();
    apply();
}

void GlobalHotkey::setEnabled(bool on)
{
    if (on == m_enabled)
        return;
    m_enabled = on;
    emit enabledChanged();
    apply();
}

void GlobalHotkey::setError(const QString &e)
{
    if (e == m_error)
        return;
    m_error = e;
    emit errorChanged();
}

#ifdef Q_OS_WIN

void GlobalHotkey::release()
{
    if (m_registered) {
        UnregisterHotKey(nullptr, m_id);
        QCoreApplication::instance()->removeNativeEventFilter(this);
        m_registered = false;
    }
}

void GlobalHotkey::apply()
{
    release();
    if (!m_enabled) {
        setError({});
        return;
    }
    const QKeySequence ks(m_sequence, QKeySequence::PortableText);
    if (ks.isEmpty() || ks.count() != 1) {
        setError(tr("Not a valid shortcut"));
        return;
    }
    const QKeyCombination kc = ks[0];
    const Qt::KeyboardModifiers mods = kc.keyboardModifiers();
    const int key = kc.key();
    UINT vk = 0;
    if ((key >= Qt::Key_A && key <= Qt::Key_Z) || (key >= Qt::Key_0 && key <= Qt::Key_9))
        vk = UINT(key);   // the virtual-key codes equal the ASCII codes
    else if (key >= Qt::Key_F1 && key <= Qt::Key_F24)
        vk = VK_F1 + UINT(key - Qt::Key_F1);
    else if (key == Qt::Key_Space)
        vk = VK_SPACE;
    if (vk == 0) {
        setError(tr("Use a letter, digit or F-key"));
        return;
    }
    UINT fs = MOD_NOREPEAT;
    if (mods & Qt::ControlModifier) fs |= MOD_CONTROL;
    if (mods & Qt::AltModifier) fs |= MOD_ALT;
    if (mods & Qt::ShiftModifier) fs |= MOD_SHIFT;
    if (mods & Qt::MetaModifier) fs |= MOD_WIN;
    if (!(fs & (MOD_CONTROL | MOD_ALT | MOD_SHIFT | MOD_WIN))) {
        setError(tr("Add Ctrl, Alt or Shift"));
        return;
    }
    static int nextId = 0x5714;
    m_id = nextId++;
    if (!RegisterHotKey(nullptr, m_id, fs, vk)) {
        setError(tr("Already used by another program"));
        return;
    }
    QCoreApplication::instance()->installNativeEventFilter(this);
    m_registered = true;
    setError({});
}

bool GlobalHotkey::nativeEventFilter(const QByteArray &eventType, void *message, qintptr *)
{
    if (m_registered && (eventType == "windows_generic_MSG" || eventType == "windows_dispatcher_MSG")) {
        const MSG *msg = static_cast<const MSG *>(message);
        if (msg->message == WM_HOTKEY && int(msg->wParam) == m_id) {
            emit activated();
            return true;
        }
    }
    return false;
}

#else

void GlobalHotkey::release() {}

void GlobalHotkey::apply()
{
    setError(m_enabled ? tr("Global hotkeys are only supported on Windows") : QString());
}

bool GlobalHotkey::nativeEventFilter(const QByteArray &, void *, qintptr *)
{
    return false;
}

#endif
