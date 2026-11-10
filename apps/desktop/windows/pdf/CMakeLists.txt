# apps/desktop/windows/pdf/CMakeLists.txt
# lr_pdf.exe: builds PDFs (pages from PDFs, turned, signed; pages from
# photos) with the pdfium.dll that ships next to LocalRoll's exe.
cmake_minimum_required(VERSION 3.14)

add_executable(lr_pdf WIN32 pdf.cpp)
target_compile_features(lr_pdf PRIVATE cxx_std_17)
target_compile_definitions(lr_pdf PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
target_compile_options(lr_pdf PRIVATE /W3 /EHsc /utf-8)
target_link_libraries(lr_pdf PRIVATE shell32)
set_target_properties(lr_pdf PROPERTIES RUNTIME_OUTPUT_DIRECTORY "$<TARGET_FILE_DIR:${BINARY_NAME}>")
