# Runs the test, records what it printed, and compares it whole with the
# expected file.
execute_process(COMMAND ${TEST} ${PLUGIN} ${OWNER} OUTPUT_FILE ${OUTPUT} RESULT_VARIABLE status)
if(NOT status EQUAL 0)
  message(FATAL_ERROR "the test exited ${status}; its output is ${OUTPUT}")
endif()
execute_process(COMMAND ${CMAKE_COMMAND} -E compare_files ${EXPECTED} ${OUTPUT} RESULT_VARIABLE differs)
if(NOT differs EQUAL 0)
  execute_process(COMMAND diff -u ${EXPECTED} ${OUTPUT})
  message(FATAL_ERROR "the output differs from ${EXPECTED}")
endif()
