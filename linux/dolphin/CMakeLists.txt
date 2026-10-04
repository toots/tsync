cmake_minimum_required(VERSION 3.22)
project(tsyncdolphin LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# The toolkit is required: a package build without it must fail, never ship
# a package set with the plugin missing (frontends/linux-desktop.md §5.1).
find_package(ECM REQUIRED NO_MODULE)
set(CMAKE_MODULE_PATH ${ECM_MODULE_PATH})
find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets Network DBus Test)
find_package(KF6 REQUIRED COMPONENTS CoreAddons KIO)

# After the toolkit is found: the plugin directory is Qt's, and computed
# before that it names a place nothing scans.
set(KDE_INSTALL_USE_QT_SYS_PATHS ON)
include(KDEInstallDirs)
include(KDECMakeSettings)

# The discovery library and its stand-in, built by dune.
set(TSYNC_MOUNTS_SO "" CACHE FILEPATH "libtsync_mounts.so")
set(TSYNC_MOUNTS_FAKE_SO "" CACHE FILEPATH "libtsync_mounts_fake.so, for the tests")
set(TSYNC_OWNER_DOUBLE "" CACHE FILEPATH "the owner double, for the tests")
set(TSYNC_MOUNTS_LIBDIR "${CMAKE_INSTALL_FULL_LIBDIR}/tsync" CACHE PATH "where libtsync_mounts.so is installed")
if(NOT EXISTS "${TSYNC_MOUNTS_SO}")
  message(FATAL_ERROR "TSYNC_MOUNTS_SO must name libtsync_mounts.so (dune build ./linux/mounts)")
endif()

execute_process(COMMAND ocamlc -where OUTPUT_VARIABLE OCAML_WHERE OUTPUT_STRIP_TRAILING_WHITESPACE RESULT_VARIABLE OCAML_RESULT)
if(NOT OCAML_RESULT EQUAL 0)
  message(FATAL_ERROR "ocamlc is needed for the headers of the discovery library's runtime")
endif()

add_library(tsynclogic STATIC resolve.cpp menu.cpp exchange.cpp)
target_include_directories(tsynclogic PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(tsynclogic PUBLIC Qt6::Core Qt6::Network)

add_library(tsyncdolphin MODULE plugin.cpp ../mounts/tsync_mounts_host.c)
target_include_directories(tsyncdolphin PRIVATE ../mounts ${OCAML_WHERE})
target_link_libraries(tsyncdolphin PRIVATE tsynclogic KF6::KIOWidgets KF6::CoreAddons Qt6::Gui Qt6::Widgets Qt6::DBus ${TSYNC_MOUNTS_SO})
# The search path recorded in the plugin is the installed one from the start,
# and never the directory the discovery library was linked from, so that an
# artifact taken from the build tree names no build directory.
set_target_properties(tsyncdolphin PROPERTIES
  PREFIX ""
  BUILD_WITH_INSTALL_RPATH ON
  INSTALL_RPATH_USE_LINK_PATH OFF
  INSTALL_RPATH "${TSYNC_MOUNTS_LIBDIR}")
install(TARGETS tsyncdolphin DESTINATION ${KDE_INSTALL_PLUGINDIR}/kf6/kfileitemaction)

if(EXISTS "${TSYNC_MOUNTS_FAKE_SO}")
  enable_testing()
  get_filename_component(TSYNC_MOUNTS_FAKE_DIR "${TSYNC_MOUNTS_FAKE_SO}" DIRECTORY)
  add_executable(logic_test tests/logic_test.cpp ../mounts/tsync_mounts_host.c)
  target_include_directories(logic_test PRIVATE ../mounts ${OCAML_WHERE})
  target_link_libraries(logic_test PRIVATE tsynclogic KF6::CoreAddons ${TSYNC_MOUNTS_FAKE_SO})
  set_target_properties(logic_test PROPERTIES BUILD_RPATH "${TSYNC_MOUNTS_FAKE_DIR}")
  add_test(NAME logic COMMAND ${CMAKE_COMMAND}
    -DTEST=$<TARGET_FILE:logic_test> -DPLUGIN=$<TARGET_FILE:tsyncdolphin> -DOWNER=${TSYNC_OWNER_DOUBLE}
    -DEXPECTED=${CMAKE_CURRENT_SOURCE_DIR}/tests/logic_test.expected -DOUTPUT=${CMAKE_CURRENT_BINARY_DIR}/logic_test.output
    -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/compare.cmake)
  add_test(NAME search_path COMMAND ${CMAKE_COMMAND}
    -DPLUGIN=$<TARGET_FILE:tsyncdolphin> -DEXPECTED=${TSYNC_MOUNTS_LIBDIR}
    -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/search_path.cmake)
endif()
