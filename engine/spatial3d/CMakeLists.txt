cmake_minimum_required(VERSION 3.21)
project(DepthscapeSpatial3D LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Qml Quick3D Concurrent)

add_library(depthscape_spatial3d MODULE
    depthmeshgeometry.cpp
    depthmeshgeometry.h
    plugin.cpp
)
target_link_libraries(depthscape_spatial3d PRIVATE
    Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick3D Qt6::Concurrent)
set_target_properties(depthscape_spatial3d PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/qml/Depthscape/Spatial3D")

configure_file(qmldir "${CMAKE_BINARY_DIR}/qml/Depthscape/Spatial3D/qmldir" COPYONLY)
install(TARGETS depthscape_spatial3d
    LIBRARY DESTINATION qml/Depthscape/Spatial3D)
install(FILES qmldir DESTINATION qml/Depthscape/Spatial3D)
