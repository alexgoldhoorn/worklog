cmake_minimum_required(VERSION 3.16)

project(WorkLogApp VERSION 0.1 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 REQUIRED COMPONENTS Quick QuickControls2 Network Multimedia)

qt_standard_project_setup(REQUIRES 6.10)

# Content of downloaded design from Figma to Qt or similar
if (EXISTS "${CMAKE_CURRENT_LIST_DIR}/importedcontent/CMakeLists.txt")
    add_subdirectory(${CMAKE_CURRENT_LIST_DIR}/importedcontent)
endif()

qt_add_executable(appWorkLogApp
    main.cpp
)
if (WIN32)
    target_sources(appWorkLogApp PRIVATE icons/worklog.rc)   # the .exe icon
endif()

set_source_files_properties(Api.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

qt_add_qml_module(appWorkLogApp
    URI WorkLogApp
    QML_FILES
        Main.qml
        Api.qml
        TimerPage.qml
        DayPage.qml
        SettingsPage.qml
        BlockList.qml
        BlockDialog.qml
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
    SOURCES
        filedownloader.h
        filedownloader.cpp
        notifier.h
        notifier.cpp
    RESOURCES
        beep.wav
        icons/worklog-256.png
)

# Qt for iOS sets MACOSX_BUNDLE_GUI_IDENTIFIER automatically since Qt 6.1.
# If you are developing for iOS or macOS you should consider setting an
# explicit, fixed bundle identifier manually though.
# Android: our manifest and launcher icons are laid over Qt's template (android/)
set_target_properties(appWorkLogApp PROPERTIES
    QT_ANDROID_PACKAGE_SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/android
    QT_ANDROID_PACKAGE_NAME net.goldhoorn.worklog
    QT_ANDROID_APP_NAME "Worklog"
    QT_ANDROID_VERSION_NAME ${PROJECT_VERSION}
    QT_ANDROID_VERSION_CODE 1
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
#    MACOSX_BUNDLE_GUI_IDENTIFIER com.example.appWorkLogApp
    MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
    MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}
    MACOSX_BUNDLE TRUE
    WIN32_EXECUTABLE TRUE
)

target_link_libraries(appWorkLogApp
    PRIVATE Qt6::Quick Qt6::QuickControls2 Qt6::Network Qt6::Multimedia
)

install(TARGETS appWorkLogApp
    BUNDLE DESTINATION .
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)
