# apps/desktop/windows/loopback/CMakeLists.txt
# lr_loopback.exe: records the sound the PC plays (see loopback.cpp), put
# next to LocalRoll's exe.
cmake_minimum_required(VERSION 3.14)

add_executable(lr_loopback loopback.cpp)
target_compile_features(lr_loopback PRIVATE cxx_std_17)
target_compile_definitions(lr_loopback PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
target_compile_options(lr_loopback PRIVATE /W3 /EHsc /utf-8)
target_link_libraries(lr_loopback PRIVATE ole32 uuid)
set_target_properties(lr_loopback PROPERTIES RUNTIME_OUTPUT_DIRECTORY "$<TARGET_FILE_DIR:${BINARY_NAME}>")
