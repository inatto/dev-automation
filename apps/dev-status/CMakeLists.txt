cmake_minimum_required(VERSION 3.24)
project(dev_status LANGUAGES CXX)

if(NOT WIN32)
    message(FATAL_ERROR "dev-status é um aplicativo Win32 e deve ser compilado no Windows.")
endif()

add_executable(dev-status WIN32 src/main.cpp)
target_compile_features(dev-status PRIVATE cxx_std_20)
target_compile_definitions(dev-status PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
target_link_libraries(dev-status PRIVATE user32 shell32 ole32 advapi32 gdi32)

if(MSVC)
    target_compile_options(dev-status PRIVATE /W4 /permissive- /EHsc /utf-8)
    set_property(TARGET dev-status PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()
