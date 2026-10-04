# The plugin's recorded search path is the installed library directory and
# nothing else (frontends/linux-desktop.md §5.1).
execute_process(COMMAND readelf -d ${PLUGIN} OUTPUT_VARIABLE dynamic RESULT_VARIABLE status)
if(NOT status EQUAL 0)
  message(FATAL_ERROR "readelf failed on ${PLUGIN}")
endif()
string(REGEX MATCH "\\((RUNPATH|RPATH)\\)[^\n]*\\[([^]]*)\\]" found "${dynamic}")
if(NOT found)
  message(FATAL_ERROR "${PLUGIN} records no search path")
endif()
if(NOT CMAKE_MATCH_2 STREQUAL "${EXPECTED}")
  message(FATAL_ERROR "${PLUGIN} records the search path [${CMAKE_MATCH_2}], expected [${EXPECTED}]")
endif()
message(STATUS "search path: ${CMAKE_MATCH_2}")
