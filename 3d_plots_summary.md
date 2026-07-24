# 3D Plots from Tutorial Examples - Complete Summary

This document describes all 15 3D plots that were generated from the tutorial script.

## Overview
- **Total plots**: 15
- **Output directory**: `3d_plot_results/`
- **DPI**: 150 (for high-quality images)
- **Style**: Seaborn

---

## Category 1: 3D Line Plots (2 plots)

### 1. Parametric Spiral (`1_parametric_spiral.png`)
- **Type**: Parametric curve in 3D space
- **Equation**: x = sin(t), y = cos(t), z = t
- **Range**: t ∈ [0, 2π], z ∈ [0, 6.3]
- **Features**: 
  - Blue line with 100 points
  - Shows a helical/spiral trajectory
  - Color gradient not applied (single color)

### 2. Multiple 3D Lines (`2_multiple_3d_lines.png`)
- **Type**: Multiple series on same base curve
- **Base curve**: y = sin(x), x ∈ [0, 4π]
- **Series**:
  - cos(x) in green (solid line)
  - sin(2x) in red (dashed line)
- **Features**:
  - Both series share the y-axis base (sin(x))
  - Shows how different functions can be visualized in 3D

---

## Category 2: 3D Scatter Plots (2 plots)

### 3. Random Data Cloud (`3_random_data_cloud.png`)
- **Type**: 3D scatter with color mapping
- **Data**: Gaussian random distribution
- **Number of points**: 500
- **Color map**: Viridis (based on Z value)
- **Features**:
  - Semi-transparent points (alpha = 0.6)
  - Point size: 20
  - Z-axis color coding

### 4. Spherical Scatter Plot (`4_spherical_scatter.png`)
- **Type**: Spherical surface visualization
- **Math**: Points on unit sphere (r = 1)
- **Coordinate generation**: 
  - θ (theta) ∈ [0, 2π]
  - φ (phi) ∈ [0, π]
- **Color map**: Plasma (based on distance from origin)
- **Features**:
  - Shows surface points
  - Color represents radial distance

---

## Category 3: 3D Surface Plots (3 plots)

### 5. Sinusoidal Surface (`5_sinusoidal_surface.png`)
- **Type**: Periodic surface
- **Equation**: Z = sin(x) * cos(y)
- **Grid**: x, y ∈ [-5, 5], 50×50 points
- **Color map**: Coolwarm
- **Features**:
  - Edge coloring disabled
  - Alpha = 0.8 (semi-transparent)
  - Colorbar shows Z values

### 6. Terrain Surface (`6_terrain_surface.png`)
- **Type**: Multi-frequency terrain/terrain-like surface
- **Equation**: Z = sum of sine waves + offset
- **Components**:
  - sin(x/2) * cos(y/2)
  - sin(x/3) * cos(y/3)  
  - sin(x/5) * cos(y/5)
  - Constant offset: 1.5
- **Color map**: Terrain (natural-looking elevation colors)
- **Features**:
  - High alpha (0.9)
  - View angle: elevation=45°, azimuth=45°

### 7. Exponential Modulated Surface (`7_exponential_surface.png`)
- **Type**: Gaussian modulated with oscillations
- **Equation**: Z = exp(-x² - y²) * (1 + sin(2x) * cos(2y))
- **Grid**: x, y ∈ [-3, 3], 60×60 points
- **Color map**: Viridis
- **Features**:
  - View angle: elevation=30°, azimuth=-60°
  - Demonstrates Gaussian envelope with oscillations

---

## Category 4: 3D Wireframe Plots (2 plots)

### 8. Radial Wireframe (`8_radial_wireframe.png`)
- **Type**: Radial distance surface (wireframe)
- **Equation**: Z = sqrt(x² + y²)
- **Grid**: x, y ∈ [-4, 4], 20×20 points
- **Color**: Blue, linewidth=0.5
- **Features**:
  - Shows distance from origin
  - Wireframe (not solid surface)

### 9. Sinusoidal Wireframe (`9_sinusoidal_wireframe.png`)
- **Type**: Complex sinusoidal wireframe
- **Equation**: Z = sin(x/y) * 10 (with Y != 0)
- **Grid**: x, y ∈ [-10, 10], 30×30 points
- **Color**: Magenta, linewidth=0.8, alpha=0.6
- **Features**:
  - View angle: elevation=30°, azimuth=120°
  - Asymmetric grid pattern

---

## Category 5: 3D Bar Plots (2 plots)

### 10. 3D Bar Chart (`10_3d_bar_chart.png`)
- **Type**: Comparison of two datasets
- **Categories**: A, B, C, D, E
- **Datasets**:
  - Dataset 1: [3, 7, 5, 4, 6] (solid bars)
  - Dataset 2: [4, 5, 6, 8, 3] (same positions, same colors)
- **Bar dimensions**: 
  - dx = dy = 0.5
  - dz varies by value
- **Colors**: Gold, Lightgreen, Lightblue, Salmon, Plum
- **Features**:
  - Edge colors: black
  - Alpha = 0.8

### 11. Stacked 3D Bars (`11_stacked_3d_bars.png`)
- **Type**: Stacked bar chart
- **Categories**: Q1, Q2, Q3, Q4
- **Series** (stacked vertically):
  - Series 1 (navy): [25, 30, 20, 35]
  - Series 2 (teal): [15, 20, 25, 18]
  - Series 3 (coral): [10, 15, 12, 20]
- **Bar dimensions**: dx = dy = 0.5
- **Features**:
  - Alpha = 0.9
  - Shows cumulative sums

---

## Category 6: Specialized 3D Plots (3 plots)

### 12. Contour and Surface Plot (`12_contour_surface.png`)
- **Type**: Multi-panel visualization
- **Left panel (2D)**: Contour plot
  - Equation: sin(√(x² + y²))
  - 15 contour levels, viridis colormap
- **Right panel (3D)**: Surface plot
  - Same equation as contour
  - Semi-transparent surface (alpha = 0.8)
- **Features**: Two complementary views of the same function

### 13. 3D Histogram (`13_3d_histogram.png`)
- **Type**: Multi-modal distribution visualization
- **Data sources** (3 separate distributions):
  - Distribution 1: Normal(0, 0.5), centered at origin
  - Distribution 2: Normal(5, 0.5), centered at x=5
  - Distribution 3: Normal([-5, 5, 0], 0.5), centered at x=-5, y=5
- **Colors**: Cyan, Magenta, Yellow (distinct colors)
- **Features**:
  - Shows separation of different modes
  - View angle: elevation=30°, azimuth=45°
  - Axes scaled to data range

### 14. 3D Cylinder (`14_3d_cylinder.png`)
- **Type**: Volumetric surface
- **Shape**: Cylinder with top
- **Parameters**:
  - Radius: 1
  - Height: 4 (base), 6 (including top)
  - Resolution: 30×30 points
- **Color map**: Plasma
- **Features**:
  - Two surfaces: main cylinder and top
  - Edge coloring disabled
  - Box aspect ratio set to preserve proportions

---

## Category 7: Data Analysis (1 plot)

### 15. 3D Trajectory (`15_3d_trajectory.png`)
- **Type**: Time-series analysis with trajectory
- **Signals** (time domain, t ∈ [0, 10], 100 points):
  - Signal 1: sin(t) with noise (blue)
  - Signal 2: cos(t) with noise (green)
  - Signal 3: sin(2t) with noise (red)
- **Trajectory calculation**:
  - x = t (time)
  - y = signal 1
  - z = signal 2 * sin(t)
- **Features**:
  - Upper panel: Time series plots with axes and legend
  - Lower panel: 3D trajectory with final point highlighted (red dot, size=100)
  - View angle: elevation=30°, azimuth=45°

---

## Technical Details

### Color Maps Used
- **Viridis**: Random data, exponential surface, terrain surface
- **Coolwarm**: Sinusoidal surface, contour plot
- **Plasma**: Spherical scatter, cylinder
- **Terrain**: Terrain surface
- **Custom**: Bar chart (multiple colors based on index)

### Common Settings
- **DPI**: 150 (balance between quality and file size)
- **Figure size**: Varies by plot (10×8 to 12×10)
- **Labels**: X, Y, Z labels on all plots
- **Titles**: Descriptive title on each plot

### Python Libraries Used
- `numpy`: Array manipulation and numerical functions
- `matplotlib.pyplot`: Plotting interface
- `mpl_toolkits.mplot3d`: 3D plotting toolkit
- `matplotlib.cm`: Color map utilities

---

## Usage Notes
- All plots use `plt.tight_layout()` to prevent label overlap
- Colormaps help distinguish data values visually
- Alpha transparency used for better visualization of multiple elements
- View angles vary to show different aspects of surfaces and trajectories
- Grid points are chosen to create smooth, representative visualizations

## Expected Output
When the script executes successfully, it will generate:
1. 15 PNG image files in the `3d_plot_results/` directory
2. Each file named according to its plot number and description
3. Console output showing progress (plot numbers with descriptions)
4. Final summary listing all plots generated