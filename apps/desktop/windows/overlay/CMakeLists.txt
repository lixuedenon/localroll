# apps/desktop/windows/overlay/CMakeLists.txt
# lr_overlay.exe: the screen pen's transparent layer (see overlay.cpp),
# put next to LocalRoll's exe.
cmake_minimum_required(VERSION 3.14)

add_executable(lr_overlay WIN32 overlay.cpp)
target_compile_features(lr_overlay PRIVATE cxx_std_17)
target_compile_definitions(lr_overlay PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
target_compile_options(lr_overlay PRIVATE /W3 /EHsc /utf-8)
target_link_libraries(lr_overlay PRIVATE d2d1 dwrite user32 gdi32)
# Built next to the app's exe, and installed there too.
set_target_properties(lr_overlay PROPERTIES RUNTIME_OUTPUT_DIRECTORY "$<TARGET_FILE_DIR:${BINARY_NAME}>")
install(TARGETS lr_overlay RUNTIME DESTINATION . COMPONENT Runtime)
