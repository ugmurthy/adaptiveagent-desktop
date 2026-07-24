#!/usr/bin/env python3
"""
3D Plot Generation Script
Generates all 15 3D plots from tutorial examples.

Usage:
    python generate_3d_plots.py
"""

import numpy as np
from matplotlib import cm
from mpl_toolkits.mplot3d import Axes3D
import matplotlib.pyplot as plt
import os

# Create output directory
output_dir = '3d_plot_results'
os.makedirs(output_dir, exist_ok=True)

# Set style
plt.style.use('seaborn')

print('Generating 3D plots from tutorial examples...')
print('This may take a few seconds...\n')


# ============================================
# 1. 3D Line Plots
# ============================================

# Example 1.1: Parametric Curve
print('1. Creating Parametric Spiral...')
t = np.linspace(0, 2*np.pi, 100)
x = np.sin(t)
y = np.cos(t)
z = t
fig = plt.figure(figsize=(10, 8))
ax = fig.add_subplot(111, projection='3d')
ax.plot(x, y, z, label='Spiral', linewidth=2, color='blue')
ax.set_xlabel('X')
ax.set_ylabel('Y')
ax.set_zlabel('Z')
ax.set_title('Parametric Spiral: x=sin(t), y=cos(t), z=t')
ax.legend()
ax.set_xlim(-1.1, 1.1)
ax.set_ylim(-1.1, 1.1)
ax.set_zlim(0, 6.3)
plt.tight_layout()
plt.savefig(f'{output_dir}/1_parametric_spiral.png', dpi=150)
plt.close()
print('   Saved: 1_parametric_spiral.png')

# Example 1.2: Line Plot with Multiple Series
print('2. Creating Multiple 3D Lines...')
x = np.linspace(0, 4*np.pi, 100)
y = np.sin(x)
z1 = np.cos(x)
z2 = np.sin(2*x)
fig = plt.figure(figsize=(10, 8))
ax = fig.add_subplot(111, projection='3d')
ax.plot(x, y, z1, label='cos(x)', linewidth=2, color='green')
ax.plot(x, y, z2, label='sin(2x)', linewidth=2, color='red', linestyle='--')
ax.set_xlabel('X (radians)')
ax.set_ylabel('y = sin(x)')
ax.set_zlabel('z')
ax.set_title('Multiple 3D Lines on Same Base Curve')
ax.set_xlim(0, 12.6)
ax.set_ylim(-1.1, 1.1)
ax.set_zlim(-1.1, 1.1)
plt.tight_layout()
plt.savefig(f'{output_dir}/2_multiple_3d_lines.png', dpi=150)
plt.close()
print('   Saved: 2_multiple_3d_lines.png')


# ============================================
# 2. 3D Scatter Plots
# ============================================

# Example 2.1: Random Data Cloud
print('3. Creating Random Data Cloud...')
n = 500
x = np.random.normal(0, 1, n)
y = np.random.normal(0, 1, n)
z = np.random.normal(0, 1, n)
fig = plt.figure(figsize=(10, 8))
ax = fig.add_subplot(111, projection='3d')
scatter = ax.scatter(x, y, z, c=z, cmap='viridis', s=20, alpha=0.6)
ax.set_xlabel('X')
ax.set_ylabel('Y')
ax.set_zlabel('Z')
ax.set_title('3D Scatter Plot of Random Data')
plt.colorbar(scatter, label='Z Value')
ax.set_xlim(-3, 3)
ax.set_ylim(-3, 3)
ax.set_zlim(-3, 3)
plt.tight_layout()
plt.savefig(f'{output_dir}/3_random_data_cloud.png', dpi=150)
plt.close()
print('   Saved: 3_random_data_cloud.png')

# Example 2.2: Spherical Scatter Plot
print('4. Creating Spherical Scatter Plot...')
n = 200
theta = np.linspace(0, 2*np.pi, n)
phi = np.linspace(0, np.pi, n)
theta, phi = np.meshgrid(theta, phi)
r = 1
x = r * np.sin(phi) * np.cos(theta)
y = r * np.sin(phi) * np.sin(theta)
z = r * np.cos(phi)
x_flat = x.flatten()
y_flat = y.flatten()
z_flat = z.flatten()
fig = plt.figure(figsize=(10, 8))
ax = fig.add_subplot(111, projection='3d')
scatter = ax.scatter(x_flat, y_flat, z_flat, 
                    c=np.sqrt(x_flat**2 + y_flat**2 + z_flat**2), 
                    cmap='plasma', s=10, alpha=0.7)
ax.set_xlabel('X')
ax.set_ylabel('Y')
ax.set_zlabel('Z')
ax.set_title('Spherical Surface Scatter Plot')
plt.colorbar(scatter, label='Distance from Origin')
max_range = np.array([x.max()-x.min(), y.max()-y.min(), z.max()-z.min()]).max() / 2.0
mid_x = (x.max()+x.min()) * 0.5
mid_y = (y.max()+y.min()) * 0.5
mid_z = (z.max()+z.min()) * 0.5
ax.set_xlim(mid_x - max_range, mid_x + max_range)
ax.set_ylim(mid_y - max_range, mid_y + max_range)
ax.set_zlim(mid_z - max_range, mid_z + max_range)
plt.tight_layout()
plt.savefig(f'{output_dir}/4_spherical_scatter.png', dpi=150)
plt.close()
print('   Saved: 4_spherical_scatter.png')


# ============================================
# 3. 3D Surface Plots
# ============================================

# Example 3.1: Simple Surface
print('5. Creating Sinusoidal Surface...')
x = np.linspace(-5, 5, 50)
y = np.linspace(-5, 5, 50)
X, Y = np.meshgrid(x, y)
Z = np.sin(X) * np.cos(Y)
fig = plt.figure(figsize=(12, 10))
ax = fig.add_subplot(111, projection='3d')
surface = ax.plot_surface(X, Y, Z, cmap='coolwarm', alpha=0.8, edgecolor='none')
ax.set_xlabel('X')
ax.set_ylabel('Y')
ax.set_zlabel('Z')
ax.set_title('Sinusoidal Surface: sin(x) * cos(y)')
plt.colorbar(surface, shrink=0.5, aspect=10, label='Z Value')
plt.tight_layout()
plt.savefig(f'{output_dir}/5_sinusoidal_surface.png', dpi=150)
plt.close()
print('   Saved: 5_sinusoidal_surface.png')

# Example 3.2: Terrain Surface
print('6. Creating Terrain Surface...')
x = np.linspace(-5, 5, 50)
y = np.linspace(-5, 5, 50)
X, Y = np.meshgrid(x, y)
Z = (np.sin(X/2) * np.cos(Y/2) + 
     np.sin(X/3) * np.cos(Y/3) + 
     np.sin(X/5) * np.cos(Y/5) + 1.5)
fig = plt.figure(figsize=(12, 10))
ax = fig.add_subplot(111, projection='3d')
surface = ax.plot_surface(X, Y, Z, cmap='terrain', alpha=0.9, 
                          linewidth=0, antialiased=False)
ax.set_xlabel('X')
ax.set_ylabel('Y')
ax.set_zlabel('Height')
ax.set_title('Terrain Surface: Combined Wave Functions')
plt.colorbar(surface, shrink=0.5, aspect=10, label='Elevation')
ax.view_init(elev=45, azim=45)
plt.tight_layout()
plt.savefig(f'{output_dir}/6_terrain_surface.png', dpi=150)
plt.close()
print('   Saved: 6_terrain_surface.png')

# Example 3.3: Exponential Surface
print('7. Creating Exponential Surface...')
x = np.linspace(-3, 3, 60)
y = np.linspace(-3, 3, 60)
X, Y = np.meshgrid(x, y)
Z = np.exp(-X**2 - Y**2) * (1 + np.sin(X * 2) * np.cos(Y * 2))
fig = plt.figure(figsize=(12, 10))
ax = fig.add_subplot(111, projection='3d')
surface = ax.plot_surface(X, Y, Z, cmap='viridis', alpha=0.9,
                          edgecolor='none', shade=True)
ax.set_xlabel('X')
ax.set_ylabel('Y')
ax.set_zlabel('Value')
ax.set_title('Exponential Modulated Surface')
plt.colorbar(surface, shrink=0.5, aspect=10, label='Amplitude')
ax.view_init(elev=30, azim=-60)
plt.tight_layout()
plt.savefig(f'{output_dir}/7_exponential_surface.png', dpi=150)
plt.close()
print('   Saved: 7_exponential_surface.png')


# ============================================
# 4. 3D Wireframe Plots
# ============================================

# Example 4.1: Simple Wireframe
print('8. Creating Radial Wireframe...')
x = np.linspace(-4, 4, 20)
y = np.linspace(-4, 4, 20)
X, Y = np.meshgrid(x, y)
Z = np.sqrt(X**2 + Y**2)
fig = plt.figure(figsize=(10, 8))
ax = fig.add_subplot(111, projection='3d')
wire = ax.plot_wireframe(X, Y, Z, color='blue', linewidth=0.5)
ax.set_xlabel('X')
ax.set_ylabel('Y')
ax.set_zlabel('Z')
ax.set_title('Wireframe: Radial Distance Function')
plt.colorbar(wire, shrink=0.5, aspect=10, label='Distance')
plt.tight_layout()
plt.savefig(f'{output_dir}/8_radial_wireframe.png', dpi=150)
plt.close()
print('   Saved: 8_radial_wireframe.png')

# Example 4.2: Grid Surface Wireframe
print('9. Creating Sinusoidal Wireframe...')
x = np.linspace(-10, 10, 30)
y = np.linspace(-10, 10, 30)
X, Y = np.meshgrid(x, y)
Z = (np.sin(X/Y) if Y != 0 else 0) * 10
fig = plt.figure(figsize=(12, 10))
ax = fig.add_subplot(111, projection='3d')
wire = ax.plot_wireframe(X, Y, Z, color='magenta', 
                         linewidth=0.8, alpha=0.6)
ax.set_xlabel('X')
ax.set_ylabel('Y')
ax.set_zlabel('Z')
ax.set_title('Wireframe: Sinusoidal Grid Function')
ax.view_init(elev=30, azim=120)
plt.tight_layout()
plt.savefig(f'{output_dir}/9_sinusoidal_wireframe.png', dpi=150)
plt.close()
print('   Saved: 9_sinusoidal_wireframe.png')


# ============================================
# 5. 3D Bar Plots
# ============================================

# Example 5.1: 3D Bar Chart
print('10. Creating 3D Bar Chart...')
categories = ['A', 'B', 'C', 'D', 'E']
values1 = [3, 7, 5, 4, 6]
values2 = [4, 5, 6, 8, 3]
fig = plt.figure(figsize=(12, 10))
ax = fig.add_subplot(111, projection='3d')
x_pos = np.arange(len(categories))
y_pos = np.zeros(len(categories))
dx = 0.5
dy = 0.5
colors = ['gold', 'lightgreen', 'lightblue', 'salmon', 'plum']
for i, (x, y, z, dx, dy, w, color) in enumerate(
        zip(x_pos, y_pos, values1, [dx]*len(categories), 
            [dy]*len(categories), [0]*len(categories), colors)):
    ax.bar3d(x, y, z, dx, dy, w, color=color, alpha=0.8, edgecolor='black')
ax.set_xticks(x_pos)
ax.set_xticklabels(categories)
ax.set_xlabel('Category')
ax.set_ylabel('Y Position')
ax.set_zlabel('Value')
ax.set_title('3D Bar Chart: Comparison of Two Datasets')
ax.set_zlim(0, max(max(values1), max(values2)) * 1.2)
plt.tight_layout()
plt.savefig(f'{output_dir}/10_3d_bar_chart.png', dpi=150)
plt.close()
print('   Saved: 10_3d_bar_chart.png')

# Example 5.2: Stacked 3D Bars
print('11. Creating Stacked 3D Bars...')
categories = ['Q1', 'Q2', 'Q3', 'Q4']
value1 = [25, 30, 20, 35]
value2 = [15, 20, 25, 18]
value3 = [10, 15, 12, 20]
fig = plt.figure(figsize=(12, 10))
ax = fig.add_subplot(111, projection='3d')
x_pos = np.arange(len(categories))
z_pos = np.zeros(len(categories))
dx = 0.5
dy = 0.5
dz = [value1[i] for i in range(len(categories))]
colors = ['navy', 'teal', 'coral']
for i, (x, y, z, dx, dy, dz, color) in enumerate(
        zip(x_pos, y_pos, z_pos, [dx]*len(categories), 
            [dy]*len(categories), dz, colors)):
    ax.bar3d(x, y, z, dx, dy, dz, color=color, alpha=0.9)
ax.set_xticks(x_pos)
ax.set_xticklabels(categories)
ax.set_xlabel('Quarter')
ax.set_ylabel('Y Position')
ax.set_zlabel('Value')
ax.set_title('3D Stacked Bar Chart: Quarterly Performance')
ax.set_zlim(0, max(sum(value1), sum(value2), sum(value3)) * 1.1)
plt.tight_layout()
plt.savefig(f'{output_dir}/11_stacked_3d_bars.png', dpi=150)
plt.close()
print('   Saved: 11_stacked_3d_bars.png')


# ============================================
# 6. Specialized 3D Plots
# ============================================

# Example 6.1: Contour Plot in 3D
print('12. Creating Contour and Surface Plot...')
x = np.linspace(-5, 5, 50)
y = np.linspace(-5, 5, 50)
X, Y = np.meshgrid(x, y)
Z = np.sin(np.sqrt(X**2 + Y**2))
fig = plt.figure(figsize=(14, 5))
ax1 = fig.add_subplot(121)
contour = ax1.contour(X, Y, Z, levels=15, cmap='viridis')
ax1.set_xlabel('X')
ax1.set_ylabel('Y')
ax1.set_title('2D Contour Plot')
ax2 = fig.add_subplot(122, projection='3d')
surface = ax2.plot_surface(X, Y, Z, cmap='viridis', alpha=0.8)
ax2.set_xlabel('X')
ax2.set_ylabel('Y')
ax2.set_zlabel('Z')
ax2.set_title('3D Surface Plot')
plt.tight_layout()
plt.savefig(f'{output_dir}/12_contour_surface.png', dpi=150)
plt.close()
print('   Saved: 12_contour_surface.png')

# Example 6.2: 3D Histogram
print('13. Creating 3D Histogram...')
np.random.seed(42)
n_samples = 500
data1 = np.random.normal(0, 0.5, (n_samples, 3))
data2 = np.random.normal(5, 0.5, (n_samples, 3))
data3 = np.random.normal([-5, 5, 0], 0.5, (n_samples, 3))
data = np.vstack([data1, data2, data3])
colors = ['cyan'] * n_samples + ['magenta'] * n_samples + ['yellow'] * n_samples
fig = plt.figure(figsize=(10, 8))
ax = fig.add_subplot(111, projection='3d')
scatter = ax.scatter(data[:, 0], data[:, 1], data[:, 2], 
                     c=colors, s=10, alpha=0.6)
ax.set_xlabel('Dimension X')
ax.set_ylabel('Dimension Y')
ax.set_zlabel('Dimension Z')
ax.set_title('3D Histogram: Multi-modal Distribution')
ax.view_init(elev=30, azim=45)
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
plt.savefig(f'{output_dir}/13_3d_histogram.png', dpi=150)
plt.close()
print('   Saved: 13_3d_histogram.png')

# Example 6.3: 3D Cylinder
print('14. Creating 3D Cylinder...')
theta = np.linspace(0, 2*np.pi, 30)
height = np.linspace(0, 4, 30)
theta, height = np.meshgrid(theta, height)
r = 1
x = r * np.cos(theta)
y = r * np.sin(theta)
z = height * 2
fig = plt.figure(figsize=(10, 8))
ax = fig.add_subplot(111, projection='3d')
surface = ax.plot_surface(x, y, z, cmap='plasma', alpha=0.8, edgecolor='none')
z_top = z[:, -1:]*1.5
x_top = x[:, -1:] * 1.5
y_top = y[:, -1:] * 1.5
surface_top = ax.plot_surface(x_top, y_top, z_top, 
                               cmap='plasma', alpha=0.8, edgecolor='none')
ax.set_xlabel('X')
ax.set_ylabel('Y')
ax.set_zlabel('Z')
ax.set_title('3D Cylinder Visualization')
plt.colorbar(surface, shrink=0.5, aspect=10, label='Height')
ax.set_box_aspect([r*1.5, r*1.5, 8])
plt.tight_layout()
plt.savefig(f'{output_dir}/14_3d_cylinder.png', dpi=150)
plt.close()
print('   Saved: 14_3d_cylinder.png')


# ============================================
# 7. Additional Example: 3D Trajectory
# ============================================
print('15. Creating Data Analysis 3D Trajectory...')
np.random.seed(42)
time = np.linspace(0, 10, 100)
signal1 = np.sin(time) + np.random.normal(0, 0.1, 100)
signal2 = np.cos(time) + np.random.normal(0, 0.1, 100)
signal3 = np.sin(2*time) + np.random.normal(0, 0.1, 100)
x = time
y = signal1
z = signal2 * np.sin(time)
fig = plt.figure(figsize=(12, 8))
ax1 = fig.add_subplot(211)
ax1.plot(time, signal1, label='Signal 1', color='blue')
ax1.plot(time, signal2, label='Signal 2', color='green')
ax1.plot(time, signal3, label='Signal 3', color='red')
ax1.set_xlabel('Time')
ax1.set_ylabel('Amplitude')
ax1.set_title('Time Series Analysis')
ax1.legend()
ax1.grid(True, alpha=0.3)
ax2 = fig.add_subplot(212, projection='3d')
trajectory = ax2.plot(x, y, z, label='Trajectory', color='purple', linewidth=2)
scatter = ax2.scatter(x[-1], y[-1], z[-1], color='red', s=100, label='Final Point')
ax2.set_xlabel('Time')
ax2.set_ylabel('Signal 1')
ax2.set_zlabel('Signal 2 * sin(time)')
ax2.set_title('3D Trajectory of Analyzed Signals')
ax2.legend()
ax2.view_init(elev=30, azim=45)
plt.tight_layout()
plt.savefig(f'{output_dir}/15_3d_trajectory.png', dpi=150)
plt.close()
print('   Saved: 15_3d_trajectory.png')

print(f'\n✅ All plots generated successfully in {output_dir}/')
print(f'   Total plots: 15')

# Create a summary image
all_plots = [
    '1_parametric_spiral.png',
    '2_multiple_3d_lines.png',
    '3_random_data_cloud.png',
    '4_spherical_scatter.png',
    '5_sinusoidal_surface.png',
    '6_terrain_surface.png',
    '7_exponential_surface.png',
    '8_radial_wireframe.png',
    '9_sinusoidal_wireframe.png',
    '10_3d_bar_chart.png',
    '11_stacked_3d_bars.png',
    '12_contour_surface.png',
    '13_3d_histogram.png',
    '14_3d_cylinder.png',
    '15_3d_trajectory.png'
]

print('\n📋 Summary of generated plots:')
for i, plot in enumerate(all_plots, 1):
    print(f'  {i:2d}. {plot}')