# Matplotlib 3D Plotting Tutorial

## Overview

Matplotlib is a powerful Python library for creating static, animated, and interactive visualizations. Its 3D plotting toolkit allows you to create sophisticated three-dimensional visualizations that can help you understand complex data structures and patterns.

## Prerequisites

```python
import matplotlib.pyplot as plt
from matplotlib import cm
from mpl_toolkits.mplot3d import Axes3D
import numpy as np
```

## Basic 3D Plot Setup

First, let's create a basic 3D figure:

```python
# Create a figure and 3D axis
fig = plt.figure(figsize=(10, 8))
ax = fig.add_subplot(111, projection='3d')

# Plot something (we'll add examples below)
ax.set_xlabel('X Axis')
ax.set_ylabel('Y Axis')
ax.set_zlabel('Z Axis')
plt.title('Basic 3D Plot')
```

---

## 1. 3D Line Plots

### Example 1.1: Parametric Curve

```python
import numpy as np
from matplotlib import cm
from mpl_toolkits.mplot3d import Axes3D
import matplotlib.pyplot as plt

# Generate parameter values
t = np.linspace(0, 2*np.pi, 100)

# Create parametric functions
x = np.sin(t)
y = np.cos(t)
z = t

# Create figure
fig = plt.figure(figsize=(10, 8))
ax = fig.add_subplot(111, projection='3d')

# Plot the 3D line
ax.plot(x, y, z, label='Spiral', linewidth=2, color='blue')

# Set labels and title
ax.set_xlabel('X')
ax.set_ylabel('Y')
ax.set_zlabel('Z')
ax.set_title('Parametric Spiral: x=sin(t), y=cos(t), z=t')
ax.legend()

# Set axis limits
ax.set_xlim(-1.1, 1.1)
ax.set_ylim(-1.1, 1.1)
ax.set_zlim(0, 6.3)

plt.tight_layout()
plt.show()
```

### Example 1.2: Line Plot with Multiple Series

```python
# Generate data for multiple lines
x = np.linspace(0, 4*np.pi, 100)
y = np.sin(x)
z1 = np.cos(x)
z2 = np.sin(2*x)

# Create figure
fig = plt.figure(figsize=(10, 8))
ax = fig.add_subplot(111, projection='3d')

# Plot multiple lines
ax.plot(x, y, z1, label='cos(x)', linewidth=2, color='green')
ax.plot(x, y, z2, label='sin(2x)', linewidth=2, color='red', linestyle='--')

# Set labels and title
ax.set_xlabel('X (radians)')
ax.set_ylabel('y = sin(x)')
ax.set_zlabel('z')
ax.set_title('Multiple 3D Lines on Same Base Curve')

# Set axis limits
ax.set_xlim(0, 12.6)
ax.set_ylim(-1.1, 1.1)
ax.set_zlim(-1.1, 1.1)

plt.tight_layout()
plt.show()
```

---

## 2. 3D Scatter Plots

### Example 2.1: Random Data Cloud

```python
# Generate random data
n = 500
x = np.random.normal(0, 1, n)
y = np.random.normal(0, 1, n)
z = np.random.normal(0, 1, n)

# Create figure
fig = plt.figure(figsize=(10, 8))
ax = fig.add_subplot(111, projection='3d')

# Create scatter plot
scatter = ax.scatter(x, y, z, c=z, cmap='viridis', s=20, alpha=0.6)

# Set labels and title
ax.set_xlabel('X')
ax.set_ylabel('Y')
ax.set_zlabel('Z')
ax.set_title('3D Scatter Plot of Random Data')

# Add colorbar
plt.colorbar(scatter, label='Z Value')

# Set axis limits
ax.set_xlim(-3, 3)
ax.set_ylim(-3, 3)
ax.set_zlim(-3, 3)

plt.tight_layout()
plt.show()
```

### Example 2.2: Spherical Scatter Plot

```python
# Generate spherical coordinates
n = 200
theta = np.linspace(0, 2*np.pi, n)
phi = np.linspace(0, np.pi, n)
theta, phi = np.meshgrid(theta, phi)

# Convert to Cartesian coordinates
r = 1  # Radius
x = r * np.sin(phi) * np.cos(theta)
y = r * np.sin(phi) * np.sin(theta)
z = r * np.cos(phi)

# Flatten arrays for scatter plot
x_flat = x.flatten()
y_flat = y.flatten()
z_flat = z.flatten()

# Create figure
fig = plt.figure(figsize=(10, 8))
ax = fig.add_subplot(111, projection='3d')

# Create scatter plot
scatter = ax.scatter(x_flat, y_flat, z_flat, 
                    c=np.sqrt(x_flat**2 + y_flat**2 + z_flat**2), 
                    cmap='plasma', s=10, alpha=0.7)

# Set labels and title
ax.set_xlabel('X')
ax.set_ylabel('Y')
ax.set_zlabel('Z')
ax.set_title('Spherical Surface Scatter Plot')

# Add colorbar
plt.colorbar(scatter, label='Distance from Origin')

# Set equal aspect ratio
max_range = np.array([x.max()-x.min(), y.max()-y.min(), z.max()-z.min()]).max() / 2.0
mid_x = (x.max()+x.min()) * 0.5
mid_y = (y.max()+y.min()) * 0.5
mid_z = (z.max()+z.min()) * 0.5
ax.set_xlim(mid_x - max_range, mid_x + max_range)
ax.set_ylim(mid_y - max_range, mid_y + max_range)
ax.set_zlim(mid_z - max_range, mid_z + max_range)

plt.tight_layout()
plt.show()
```

---

## 3. 3D Surface Plots

### Example 3.1: Simple Surface

```python
# Generate grid data
x = np.linspace(-5, 5, 50)
y = np.linspace(-5, 5, 50)
X, Y = np.meshgrid(x, y)
Z = np.sin(X) * np.cos(Y)

# Create figure
fig = plt.figure(figsize=(12, 10))
ax = fig.add_subplot(111, projection='3d')

# Create surface plot
surface = ax.plot_surface(X, Y, Z, cmap='coolwarm', alpha=0.8, edgecolor='none')

# Set labels and title
ax.set_xlabel('X')
ax.set_ylabel('Y')
ax.set_zlabel('Z')
ax.set_title('Sinusoidal Surface: sin(x) * cos(y)')

# Add colorbar
fig.colorbar(surface, shrink=0.5, aspect=10, label='Z Value')

plt.tight_layout()
plt.show()
```

### Example 3.2: Mountain Range Surface

```python
# Generate terrain-like data
x = np.linspace(-5, 5, 50)
y = np.linspace(-5, 5, 50)
X, Y = np.meshgrid(x, y)

# Combine multiple wave functions for terrain
Z = (np.sin(X/2) * np.cos(Y/2) + 
     np.sin(X/3) * np.cos(Y/3) + 
     np.sin(X/5) * np.cos(Y/5) + 1.5)

# Create figure
fig = plt.figure(figsize=(12, 10))
ax = fig.add_subplot(111, projection='3d')

# Create surface plot
surface = ax.plot_surface(X, Y, Z, cmap='terrain', alpha=0.9, 
                          linewidth=0, antialiased=False)

# Set labels and title
ax.set_xlabel('X')
ax.set_ylabel('Y')
ax.set_zlabel('Height')
ax.set_title('Terrain Surface: Combined Wave Functions')

# Add colorbar
fig.colorbar(surface, shrink=0.5, aspect=10, label='Elevation')

# Set view angle
ax.view_init(elev=45, azim=45)

plt.tight_layout()
plt.show()
```

### Example 3.3: Exponential Surface

```python
# Generate exponential surface
x = np.linspace(-3, 3, 60)
y = np.linspace(-3, 3, 60)
X, Y = np.meshgrid(x, y)
Z = np.exp(-X**2 - Y**2) * (1 + np.sin(X * 2) * np.cos(Y * 2))

# Create figure
fig = plt.figure(figsize=(12, 10))
ax = fig.add_subplot(111, projection='3d')

# Create surface plot with custom colors
colors = cm.viridis(0.7 * Z.max())
surface = ax.plot_surface(X, Y, Z, cmap='viridis', alpha=0.9,
                          edgecolor='none', shade=True)

# Set labels and title
ax.set_xlabel('X')
ax.set_ylabel('Y')
ax.set_zlabel('Value')
ax.set_title('Exponential Modulated Surface')

# Add colorbar
fig.colorbar(surface, shrink=0.5, aspect=10, label='Amplitude')

# Set view angle
ax.view_init(elev=30, azim=-60)

plt.tight_layout()
plt.show()
```

---

## 4. 3D Wireframe Plots

### Example 4.1: Simple Wireframe

```python
# Generate wireframe data
x = np.linspace(-4, 4, 20)
y = np.linspace(-4, 4, 20)
X, Y = np.meshgrid(x, y)
Z = np.sqrt(X**2 + Y**2)  # Distance from origin

# Create figure
fig = plt.figure(figsize=(10, 8))
ax = fig.add_subplot(111, projection='3d')

# Create wireframe plot
wire = ax.plot_wireframe(X, Y, Z, color='blue', linewidth=0.5)

# Set labels and title
ax.set_xlabel('X')
ax.set_ylabel('Y')
ax.set_zlabel('Z')
ax.set_title('Wireframe: Radial Distance Function')

# Add colorbar
fig.colorbar(wire, shrink=0.5, aspect=10, label='Distance')

plt.tight_layout()
plt.show()
```

### Example 4.2: Grid Surface Wireframe

```python
# Generate grid data
x = np.linspace(-10, 10, 30)
y = np.linspace(-10, 10, 30)
X, Y = np.meshgrid(x, y)
Z = (np.sin(X/Y) if Y != 0 else 0) * 10  # Riemann zeta-like function

# Create figure
fig = plt.figure(figsize=(12, 10))
ax = fig.add_subplot(111, projection='3d')

# Create wireframe plot
wire = ax.plot_wireframe(X, Y, Z, color='magenta', 
                         linewidth=0.8, alpha=0.6)

# Set labels and title
ax.set_xlabel('X')
ax.set_ylabel('Y')
ax.set_zlabel('Z')
ax.set_title('Wireframe: Sinusoidal Grid Function')

# Set view angle
ax.view_init(elev=30, azim=120)

plt.tight_layout()
plt.show()
```

---

## 5. 3D Bar Plots

### Example 5.1: 3D Bar Chart

```python
# Create sample data
categories = ['A', 'B', 'C', 'D', 'E']
values1 = [3, 7, 5, 4, 6]
values2 = [4, 5, 6, 8, 3]

# Create figure
fig = plt.figure(figsize=(12, 10))
ax = fig.add_subplot(111, projection='3d')

# Convert to 3D coordinates
x_pos = np.arange(len(categories))
y_pos = np.zeros(len(categories))
dx = 0.5
dy = 0.5

# Plot bars
colors = ['gold', 'lightgreen', 'lightblue', 'salmon', 'plum']
for i, (x, y, z, u, v, w, color) in enumerate(
        zip(x_pos, y_pos, values1, [dx]*len(categories), 
            [dy]*len(categories), [0]*len(categories), colors)):
    ax.bar3d(x, y, z, dx, dy, w, color=color, alpha=0.8, edgecolor='black')

# Set labels and title
ax.set_xticks(x_pos)
ax.set_xticklabels(categories)
ax.set_xlabel('Category')
ax.set_ylabel('Y Position')
ax.set_zlabel('Value')
ax.set_title('3D Bar Chart: Comparison of Two Datasets')

# Set z-axis limit
ax.set_zlim(0, max(max(values1), max(values2)) * 1.2)

plt.tight_layout()
plt.show()
```

### Example 5.2: Stacked 3D Bars

```python
# Create stacked bar data
categories = ['Q1', 'Q2', 'Q3', 'Q4']
value1 = [25, 30, 20, 35]
value2 = [15, 20, 25, 18]
value3 = [10, 15, 12, 20]

# Create figure
fig = plt.figure(figsize=(12, 10))
ax = fig.add_subplot(111, projection='3d')

# Convert to 3D coordinates
x_pos = np.arange(len(categories))
z_pos = np.zeros(len(categories))
dx = 0.5
dy = 0.5
dz = [value1[i] for i in range(len(categories))]  # dz for each bar

# Plot stacked bars
colors = ['navy', 'teal', 'coral']
for i, (x, y, z, dx, dy, dz, color) in enumerate(
        zip(x_pos, y_pos, z_pos, [dx]*len(categories), 
            [dy]*len(categories), dz, colors)):
    ax.bar3d(x, y, z, dx, dy, dz, color=color, alpha=0.9)

# Set labels and title
ax.set_xticks(x_pos)
ax.set_xticklabels(categories)
ax.set_xlabel('Quarter')
ax.set_ylabel('Y Position')
ax.set_zlabel('Value')
ax.set_title('3D Stacked Bar Chart: Quarterly Performance')

# Set z-axis limit
ax.set_zlim(0, max(sum(value1), sum(value2), sum(value3)) * 1.1)

plt.tight_layout()
plt.show()
```

---

## 6. Specialized 3D Plots

### Example 6.1: Contour Plot in 3D

```python
# Generate surface data
x = np.linspace(-5, 5, 50)
y = np.linspace(-5, 5, 50)
X, Y = np.meshgrid(x, y)
Z = np.sin(np.sqrt(X**2 + Y**2))

# Create figure
fig = plt.figure(figsize=(14, 5))

# 2D Contour plot
ax1 = fig.add_subplot(121)
contour = ax1.contour(X, Y, Z, levels=15, cmap='viridis')
ax1.set_xlabel('X')
ax1.set_ylabel('Y')
ax1.set_title('2D Contour Plot')

# 3D Surface plot
ax2 = fig.add_subplot(122, projection='3d')
surface = ax2.plot_surface(X, Y, Z, cmap='viridis', alpha=0.8)
ax2.set_xlabel('X')
ax2.set_ylabel('Y')
ax2.set_zlabel('Z')
ax2.set_title('3D Surface Plot')

plt.tight_layout()
plt.show()
```

### Example 6.2: 3D Histogram

```python
# Generate 3D histogram data
np.random.seed(42)
n_samples = 500

# Generate random points from three distributions
data1 = np.random.normal(0, 0.5, (n_samples, 3))
data2 = np.random.normal(5, 0.5, (n_samples, 3))
data3 = np.random.normal([-5, 5, 0], 0.5, (n_samples, 3))
data = np.vstack([data1, data2, data3])
colors = ['cyan'] * n_samples + ['magenta'] * n_samples + ['yellow'] * n_samples

# Create figure
fig = plt.figure(figsize=(10, 8))
ax = fig.add_subplot(111, projection='3d')

# Create scatter histogram
scatter = ax.scatter(data[:, 0], data[:, 1], data[:, 2], 
                     c=colors, s=10, alpha=0.6)

# Set labels and title
ax.set_xlabel('Dimension X')
ax.set_ylabel('Dimension Y')
ax.set_zlabel('Dimension Z')
ax.set_title('3D Histogram: Multi-modal Distribution')

# Set view angle
ax.view_init(elev=30, azim=45)

# Set equal aspect ratio
max_range = np.array([data[:, 0].max()-data[:, 0].min(), 
                      data[:, 1].max()-data[:, 1].min(),
                      data[:, 2].max()-data[:, 2].min()]).max() / 2.0
mid_x = (data[:, 0].max()+data[:, 0].min()) * 0.5
mid_y = (data[:, 1].max()+data[:, 1].min()) * 0.5
mid_z = (data[:, 2].max()+data[:, 2].min()) * 0.5
ax.set_xlim(mid_x - max_range, mid_x + max_range)
ax.set_ylim(mid_y - max_range, mid_y + max_range)
ax.set_zlim(mid_z - max_range, mid_z + max_range)

plt.tight_layout()
plt.show()
```

### Example 6.3: 3D Cylinder

```python
# Generate cylinder data
theta = np.linspace(0, 2*np.pi, 30)
height = np.linspace(0, 4, 30)
theta, height = np.meshgrid(theta, height)

# Radius and x, y, z coordinates
r = 1
x = r * np.cos(theta)
y = r * np.sin(theta)
z = height * 2  # Scale height

# Create figure
fig = plt.figure(figsize=(10, 8))
ax = fig.add_subplot(111, projection='3d')

# Create surface plot for cylinder
surface = ax.plot_surface(x, y, z, cmap='plasma', alpha=0.8, edgecolor='none')

# Add another surface for top cap
z_top = z[:, -1:]*1.5  # Top surface
x_top = x[:, -1:] * 1.5
y_top = y[:, -1:] * 1.5
surface_top = ax.plot_surface(x_top, y_top, z_top, 
                               cmap='plasma', alpha=0.8, edgecolor='none')

# Set labels and title
ax.set_xlabel('X')
ax.set_ylabel('Y')
ax.set_zlabel('Z')
ax.set_title('3D Cylinder Visualization')

# Add colorbar
fig.colorbar(surface, shrink=0.5, aspect=10, label='Height')

# Set aspect ratio
ax.set_box_aspect([r*1.5, r*1.5, 8])  # Match ratio to cylinder dimensions

plt.tight_layout()
plt.show()
```

---

## 7. Plot Customization Tips

### Customizing Views

```python
# After creating any 3D plot:

# Change elevation and azimuth angles
ax.view_init(elev=30, azim=45)

# Freeze the view (useful for animations)
ax.view_init(elev=30, azim=45)  # Keep this fixed

# Reset to default view
ax.view_init(elev=20, azim=0)
```

### Setting Labels and Titles

```python
# Add labels
ax.set_xlabel('X Axis', fontsize=12)
ax.set_ylabel('Y Axis', fontsize=12)
ax.set_zlabel('Z Axis', fontsize=12)

# Set title with custom formatting
ax.set_title('Custom Title', fontsize=14, fontweight='bold')

# Add a grid
ax.grid(True, linestyle='--', alpha=0.5)

# Toggle axis lines
ax.xaxis.pane.fill = False
ax.yaxis.pane.fill = False
ax.zaxis.pane.fill = False
```

### Styling the Plot

```python
# Customizing line properties
line = ax.plot(x, y, z, color='red', linewidth=2.5, linestyle='-')

# Customizing scatter properties
scatter = ax.scatter(x, y, z, s=100, c='blue', alpha=0.7, marker='o')

# Customizing surface properties
surface = ax.plot_surface(X, Y, Z, cmap='viridis', 
                          linewidth=0, antialiased=False, alpha=0.8)

# Set axis limits
ax.set_xlim(x_min, x_max)
ax.set_ylim(y_min, y_max)
ax.set_zlim(z_min, z_max)

# Set aspect ratio
max_range = np.array([x.max()-x.min(), y.max()-y.min(), z.max()-z.min()]).max() / 2.0
mid_x = (x.max()+x.min()) * 0.5
mid_y = (y.max()+y.min()) * 0.5
mid_z = (z.max()+z.min()) * 0.5
ax.set_xlim(mid_x - max_range, mid_x + max_range)
ax.set_ylim(mid_y - max_range, mid_y + max_range)
ax.set_zlim(mid_z - max_range, mid_z + max_range)
```

### Color Maps

```python
# Available colormaps (examples)
colormaps = ['viridis', 'plasma', 'inferno', 'magma', 
             'cividis', 'rainbow', 'jet', 'coolwarm', 
             'seismic', 'terrain', 'ocean', 'gist_earth']

# Using different colormaps for surfaces
surface1 = ax.plot_surface(X, Y, Z, cmap='viridis')
surface2 = ax.plot_surface(X, Y, Z, cmap='coolwarm')
surface3 = ax.plot_surface(X, Y, Z, cmap='magma')
```

---

## 8. Practical Examples

### Example 8.1: Interactive Plot Exploration

```python
import numpy as np
from matplotlib import cm
from mpl_toolkits.mplot3d import Axes3D
import matplotlib.pyplot as plt

# Generate sample data
t = np.linspace(0, 4*np.pi, 200)
r = np.linspace(0, 2*np.pi, 200)
T, R = np.meshgrid(t, r)

# Create a complex parametric surface
X = np.sin(T/2) * np.cos(R/2)
Y = np.sin(T/2) * np.sin(R/2)
Z = np.cos(T/2) * np.cos(R/2) + 0.5 * np.sin(T * 1.5)

# Create figure
fig = plt.figure(figsize=(14, 6))

# Plot 1: Surface plot
ax1 = fig.add_subplot(121, projection='3d')
surface1 = ax1.plot_surface(X, Y, Z, cmap='coolwarm', alpha=0.9, 
                            edgecolor='none', shade=True)
ax1.set_xlabel('X')
ax1.set_ylabel('Y')
ax1.set_zlabel('Z')
ax1.set_title('Surface Plot')

# Plot 2: Wireframe plot with different orientation
ax2 = fig.add_subplot(122, projection='3d')
wireframe = ax2.plot_wireframe(X, Y, Z, color='green', 
                               linewidth=0.5, alpha=0.6)
ax2.set_xlabel('X')
ax2.set_ylabel('Y')
ax2.set_zlabel('Z')
ax2.set_title('Wireframe Plot')

# Add colorbar to first plot
fig.colorbar(surface1, shrink=0.5, aspect=10, label='Amplitude')

plt.tight_layout()
plt.show()
```

### Example 8.2: Data Analysis Visualization

```python
# Create sample data representing 3D data analysis
np.random.seed(42)

# Generate time series data
time = np.linspace(0, 10, 100)
signal1 = np.sin(time) + np.random.normal(0, 0.1, 100)
signal2 = np.cos(time) + np.random.normal(0, 0.1, 100)
signal3 = np.sin(2*time) + np.random.normal(0, 0.1, 100)

# Create 3D trajectory
x = time
y = signal1
z = signal2 * np.sin(time)

# Create figure
fig = plt.figure(figsize=(12, 8))

# 2D time series
ax1 = fig.add_subplot(211)
ax1.plot(time, signal1, label='Signal 1', color='blue')
ax1.plot(time, signal2, label='Signal 2', color='green')
ax1.plot(time, signal3, label='Signal 3', color='red')
ax1.set_xlabel('Time')
ax1.set_ylabel('Amplitude')
ax1.set_title('Time Series Analysis')
ax1.legend()
ax1.grid(True, alpha=0.3)

# 3D trajectory
ax2 = fig.add_subplot(212, projection='3d')
trajectory = ax2.plot(x, y, z, label='Trajectory', color='purple', linewidth=2)
scatter = ax2.scatter(x[-1], y[-1], z[-1], color='red', s=100, label='Final Point')

ax2.set_xlabel('Time')
ax2.set_ylabel('Signal 1')
ax2.set_zlabel('Signal 2 * sin(time)')
ax2.set_title('3D Trajectory of Analyzed Signals')

# Add legend to 3D plot
ax2.legend()
ax2.view_init(elev=30, azim=45)

plt.tight_layout()
plt.show()
```

---

## Conclusion

This tutorial covered the fundamentals of 3D plotting with matplotlib, including:

1. **Line plots** - Creating 3D curves and multiple lines
2. **Scatter plots** - Visualizing points in 3D space
3. **Surface plots** - Visualizing continuous 3D functions
4. **Wireframe plots** - Grid-like surfaces
5. **Bar plots** - 3D categorical comparisons
6. **Specialized plots** - Contours, histograms, and shapes
7. **Customization** - Views, labels, and styling
8. **Practical examples** - Real-world data visualization

The key takeaways are:
- Matplotlib's 3D toolkit requires the `mpl_toolkits.mplot3d` module
- Always set appropriate axis labels and titles for clarity
- Use color maps to add visual information to your plots
- Experiment with different view angles for better understanding
- The code examples provided can be run directly to see the results

Happy plotting! 📊✨