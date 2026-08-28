# The KIO plugin, built apart from dune: it is C++ against Qt and KDE
# Frameworks, which the OCaml tree has no business knowing about. Packaged on
# its own for the same reason the tray is -- see linux/deb/build.sh.
#
# The mount rules come from an OCaml object dune builds, so TSYNC_ML_SO names
# where it is rather than this guessing at a path inside _build.

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

if(NOT TSYNC_ML_SO)
  message(FATAL_ERROR
          "TSYNC_ML_SO must name the object dune built at "
          "_build/default/linux/dolphin/ml/tsync_mounts_ml.so")
endif()
if(NOT EXISTS ${TSYNC_ML_SO})
  message(FATAL_ERROR "TSYNC_ML_SO does not exist: ${TSYNC_ML_SO}")
endif()

# Where caml/callback.h lives, asked of the compiler that will be linked against
# rather than assumed from a switch name.
execute_process(COMMAND ocamlc -where
                OUTPUT_VARIABLE OCAML_LIB_DIR
                OUTPUT_STRIP_TRAILING_WHITESPACE
                RESULT_VARIABLE OCAML_WHERE_FAILED)
if(OCAML_WHERE_FAILED)
  message(FATAL_ERROR "ocamlc -where failed; no OCaml toolchain on PATH")
endif()

add_library(tsyncdolphin MODULE tsync_share_action.cpp tsync_mounts.cpp)
# KIO finds the plugin by scanning the directory, but every plugin beside it is
# named without the prefix CMake gives a module by default.
set_target_properties(tsyncdolphin PROPERTIES PREFIX "")
target_include_directories(tsyncdolphin PRIVATE ${OCAML_LIB_DIR})
target_link_libraries(
  tsyncdolphin PRIVATE KF6::KIOWidgets Qt6::Gui Qt6::Network Qt6::DBus
                       ${TSYNC_ML_SO})
# The object records its own soname, so the loader looks for libtsync_mounts.so
# and finds it beside the other tsync libraries.
set_target_properties(tsyncdolphin PROPERTIES
                      INSTALL_RPATH ${KDE_INSTALL_FULL_LIBDIR}/tsync)
install(TARGETS tsyncdolphin
        DESTINATION ${KDE_INSTALL_PLUGINDIR}/kf6/kfileitemaction)
# Installed here so the destination and the rpath above are derived from one
# libdir. The packages place it themselves, into the base tsync package -- this
# is what `make -C linux install-system` uses.
install(FILES ${TSYNC_ML_SO} DESTINATION ${KDE_INSTALL_LIBDIR}/tsync)

enable_testing()

add_executable(tsync_mounts_test tsync_mounts_test.cpp tsync_mounts.cpp)
target_include_directories(tsync_mounts_test PRIVATE ${OCAML_LIB_DIR})
# The fake answers the same name with values this test chose, so the decode is
# checked against something known rather than whatever is mounted today.
target_link_libraries(tsync_mounts_test PRIVATE Qt6::Core ${TSYNC_FAKE_ML_SO})
# Both objects carry a soname, so the loader searches by that name: point it at
# the directory dune built them in.
get_filename_component(TSYNC_ML_DIR ${TSYNC_ML_SO} DIRECTORY)
set_target_properties(tsync_mounts_test PROPERTIES BUILD_RPATH ${TSYNC_ML_DIR})
set_target_properties(tsyncdolphin PROPERTIES BUILD_RPATH ${TSYNC_ML_DIR})
add_test(NAME tsync_mounts COMMAND tsync_mounts_test)

add_executable(tsync_metadata_test tsync_metadata_test.cpp)
target_link_libraries(tsync_metadata_test PRIVATE Qt6::Core KF6::CoreAddons)
add_test(NAME tsync_metadata
         COMMAND tsync_metadata_test $<TARGET_FILE:tsyncdolphin>)
