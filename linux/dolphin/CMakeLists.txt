# The KIO plugin, built apart from dune: it is C++ against Qt and KDE
# Frameworks, which the OCaml tree has no business knowing about. Packaged on
# its own for the same reason the tray is -- see linux/deb/build.sh.

cmake_minimum_required(VERSION 3.16)
project(tsync-dolphin)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(ECM REQUIRED NO_MODULE)
set(CMAKE_MODULE_PATH ${ECM_MODULE_PATH})
include(KDEInstallDirs)

find_package(Qt6 REQUIRED COMPONENTS Core Gui Network DBus Widgets)
find_package(KF6 REQUIRED COMPONENTS KIO CoreAddons)

add_library(tsyncdolphin MODULE tsync_share_action.cpp tsync_mounts.cpp)
# KIO finds the plugin by scanning the directory, but every plugin beside it is
# named without the prefix CMake gives a module by default.
set_target_properties(tsyncdolphin PROPERTIES PREFIX "")
target_link_libraries(
  tsyncdolphin PRIVATE KF6::KIOWidgets Qt6::Gui Qt6::Network Qt6::DBus)
install(TARGETS tsyncdolphin
        DESTINATION ${KDE_INSTALL_PLUGINDIR}/kf6/kfileitemaction)

enable_testing()
add_executable(tsync_mounts_test tsync_mounts_test.cpp tsync_mounts.cpp)
target_link_libraries(tsync_mounts_test PRIVATE Qt6::Core Qt6::Network)
add_test(NAME tsync_mounts COMMAND tsync_mounts_test)

add_executable(tsync_metadata_test tsync_metadata_test.cpp)
target_link_libraries(tsync_metadata_test PRIVATE Qt6::Core KF6::CoreAddons)
add_test(NAME tsync_metadata
         COMMAND tsync_metadata_test $<TARGET_FILE:tsyncdolphin>)
