cmake_minimum_required(VERSION 3.22)
project(dev_status_linux LANGUAGES CXX)

if(NOT UNIX OR APPLE)
    message(FATAL_ERROR "dev-status-linux deve ser compilado em Linux.")
endif()

find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK3 REQUIRED IMPORTED_TARGET gtk+-3.0)
pkg_check_modules(APPINDICATOR REQUIRED IMPORTED_TARGET ayatana-appindicator3-0.1)

add_executable(dev-status-linux src/main.cpp)
target_compile_features(dev-status-linux PRIVATE cxx_std_20)
target_compile_options(dev-status-linux PRIVATE -Wall -Wextra -Wpedantic)
target_link_libraries(dev-status-linux PRIVATE PkgConfig::GTK3 PkgConfig::APPINDICATOR)
