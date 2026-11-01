# apps/desktop/windows/camera/CMakeLists.txt
# lr_camera.exe: the camera bubble (see camera.cpp), put next to
# LocalRoll's exe.
cmake_minimum_required(VERSION 3.14)

add_executable(lr_camera WIN32 camera.cpp)
target_compile_features(lr_camera PRIVATE cxx_std_17)
target_compile_definitions(lr_camera PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
target_compile_options(lr_camera PRIVATE /W3 /EHsc /utf-8)
target_link_libraries(lr_camera PRIVATE mfplat mf mfreadwrite mfuuid ole32 uuid)
set_target_properties(lr_camera PROPERTIES RUNTIME_OUTPUT_DIRECTORY "$<TARGET_FILE_DIR:${BINARY_NAME}>")
