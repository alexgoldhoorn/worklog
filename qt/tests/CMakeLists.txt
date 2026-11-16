# Qt Quick tests: the app's own QML module (same files as the app) plus tst_*.qml.
# They talk to a real server; run them with run_tests.py, which starts one on a temporary database.
set(APP_DIR ${CMAKE_CURRENT_SOURCE_DIR}/..)

set(_qml "")
foreach(f ${WL_QML_FILES})
    set_source_files_properties(${APP_DIR}/${f} PROPERTIES QT_RESOURCE_ALIAS ${f})
    list(APPEND _qml ${APP_DIR}/${f})
endforeach()
set_source_files_properties(${APP_DIR}/Api.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

set(_src "")
foreach(f ${WL_SOURCES})
    list(APPEND _src ${APP_DIR}/${f})
endforeach()
set(_res "")
foreach(f ${WL_RESOURCES})
    set_source_files_properties(${APP_DIR}/${f} PROPERTIES QT_RESOURCE_ALIAS ${f})
    list(APPEND _res ${APP_DIR}/${f})
endforeach()

qt_add_executable(tst_worklog tst_main.cpp)
qt_add_qml_module(tst_worklog
    URI WorkLogApp
    QML_FILES ${_qml}
    SOURCES ${_src}
    RESOURCES ${_res}
)
target_include_directories(tst_worklog PRIVATE ${APP_DIR})
target_compile_definitions(tst_worklog PRIVATE QUICK_TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(tst_worklog PRIVATE Qt6::Quick Qt6::QuickControls2 Qt6::Network Qt6::Multimedia
                                          Qt6::QuickTest Qt6::Test)
if (WIN32)
    target_link_libraries(tst_worklog PRIVATE Advapi32)
endif()
