cmake_minimum_required(VERSION 3.16)

option(WORKLOG_TESTS "Build the Qt Quick tests (tests/); they need a running server, see tests/run_tests.py" OFF)

project(WorkLogApp VERSION 0.3 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 REQUIRED COMPONENTS Quick QuickControls2 Network Multimedia)
if (WIN32)
    find_package(Qt6 REQUIRED COMPONENTS Widgets)   # the tray icon (Qt Labs Platform); not needed on Android
endif()
if (WORKLOG_TESTS)
    find_package(Qt6 REQUIRED COMPONENTS QuickTest Test)
endif()

qt_standard_project_setup(REQUIRES 6.10)

qt_add_executable(appWorkLogApp
    main.cpp
)
if (NOT ANDROID)
    target_sources(appWorkLogApp PRIVATE singleinstance.h singleinstance.cpp)   # one running copy per user
endif()
target_compile_definitions(appWorkLogApp PRIVATE WORKLOG_VERSION="${PROJECT_VERSION}")   # Qt.application.version
if (WIN32)
    target_sources(appWorkLogApp PRIVATE icons/worklog.rc)   # the .exe icon
endif()

set_source_files_properties(Api.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

# the app's QML module is built twice from these lists: for the app and for the tests (tests/)
set(WL_QML_FILES
    Main.qml
    Api.qml
    TimerPage.qml
    DayPage.qml
    WeekPage.qml
    FindPage.qml
    ChipMulti.qml
    SettingsPage.qml
    BlockList.qml
    BlockDialog.qml
    DatePicker.qml
    QueueState.qml
    ChipRow.qml
    Card.qml
    Caption.qml
    NoticeBanner.qml
    Snackbar.qml
    Tile.qml
    WeekBars.qml
    ActionButton.qml
    ExpectedPage.qml
    ExportButtons.qml
    ReportsPage.qml
    ColumnChart.qml
    RankedBars.qml
    Heatmap.qml
    DataTable.qml
    PomodoroPage.qml
    TrayController.qml
    IdleWatcher.qml
    WindowState.qml
    HotkeyField.qml
)
set(WL_SOURCES
    filedownloader.h
    filedownloader.cpp
    notifier.h
    notifier.cpp
    secretstore.h
    secretstore.cpp
    globalhotkey.h
    globalhotkey.cpp
    idlemonitor.h
    idlemonitor.cpp
    autostart.h
    autostart.cpp
    timerwidget.h
    timerwidget.cpp
    biometric.h
    biometric.cpp
)
set(WL_RESOURCES
    beep.wav
    icons/worklog-256.png
    icons/tray-working.png
    icons/tray-break.png
    icons/tray-stopped.png
    icons/tray-offline.png
)

qt_add_qml_module(appWorkLogApp
    URI WorkLogApp
    QML_FILES ${WL_QML_FILES}
    SOURCES ${WL_SOURCES}
    RESOURCES ${WL_RESOURCES}
)

# Android's versionCode follows the project version (0.2 -> 2, 1.3 -> 103), so a release needs one bump
math(EXPR WL_ANDROID_VERSION_CODE "${PROJECT_VERSION_MAJOR} * 100 + ${PROJECT_VERSION_MINOR}")

# Android: our manifest and launcher icons are laid over Qt's template (android/)
set_target_properties(appWorkLogApp PROPERTIES
    QT_ANDROID_PACKAGE_SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/android
    QT_ANDROID_PACKAGE_NAME net.goldhoorn.worklog
    QT_ANDROID_APP_NAME "Worklog"
    QT_ANDROID_VERSION_NAME ${PROJECT_VERSION}
    QT_ANDROID_VERSION_CODE ${WL_ANDROID_VERSION_CODE}
)

if (ANDROID)
    # Qt's TLS backend on Android is OpenSSL, which the APK has to bring along
    # (KDAB's android_openssl, installed by Qt Creator into the SDK)
    set(ANDROID_OPENSSL_CMAKE "${ANDROID_SDK_ROOT}/android_openssl/android_openssl.cmake")
    if (EXISTS "${ANDROID_OPENSSL_CMAKE}")
        include("${ANDROID_OPENSSL_CMAKE}")
        add_android_openssl_libraries(appWorkLogApp)
    else()
        message(WARNING "No ${ANDROID_OPENSSL_CMAKE}: https:// servers won't work")
    endif()
endif()

set_target_properties(appWorkLogApp PROPERTIES
    MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
    MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}
    MACOSX_BUNDLE TRUE
    WIN32_EXECUTABLE TRUE
)

target_link_libraries(appWorkLogApp
    PRIVATE Qt6::Quick Qt6::QuickControls2 Qt6::Network Qt6::Multimedia
)
if (WIN32)
    target_link_libraries(appWorkLogApp PRIVATE Advapi32 User32 Qt6::Widgets)   # Credential Manager (secretstore.cpp), RegisterHotKey (globalhotkey.cpp)
endif()

install(TARGETS appWorkLogApp
    BUNDLE DESTINATION .
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)

if (WORKLOG_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()
