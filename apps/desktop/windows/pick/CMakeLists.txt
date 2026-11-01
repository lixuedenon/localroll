# apps/desktop/windows/pick/CMakeLists.txt
# lr_pick.exe: point at the part of the screen to record (see pick.cpp),
# put next to LocalRoll's exe.
cmake_minimum_required(VERSION 3.14)

add_executable(lr_pick WIN32 pick.cpp)
target_compile_features(lr_pick PRIVATE cxx_std_17)
target_compile_definitions(lr_pick PRIVATE UNICODE _UNICODE NOMINMAX)
# (Not WIN32_LEAN_AND_MEAN: UI Automation needs the OLE headers.)
target_compile_options(lr_pick PRIVATE /W3 /EHsc /utf-8)
target_link_libraries(lr_pick PRIVATE ole32 oleaut32 oleacc uuid shell32 uiautomationcore)
set_target_properties(lr_pick PROPERTIES RUNTIME_OUTPUT_DIRECTORY "$<TARGET_FILE_DIR:${BINARY_NAME}>")
