#!/usr/bin/env python3
"""generate-phase2-plots.py — Phase 2 & 3 analysis and publication-quality plots.

Produces 6 figures from Phase 2 degradation curve data:
  P2.1  Degradation curve with inverse-quota model overlay (the key figure)
  P2.2  CFS throttle ratio vs degradation ratio
  P2.3  Latency distributions at each CPU level (violin + box)
  P2.4  Phase 1 cross-profile comparison bar chart (RQ1 context)
  P2.5  Combined summary: degradation curve + CFS throttle on dual axis
  P2.6  Latency heatmap: rep-level consistency

Also prints statistical analysis to stdout (R², Pearson correlation, etc.).

Usage: python scripts/generate-phase2-plots.py
Output: results/phase2/plots/*.png
"""

import os
import sys
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter
import matplotlib.patches as mpatches

# ── Configuration ───────────────────────────────────────────────────────────

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.join(SCRIPT_DIR, "..")
P2_DATA = os.path.join(REPO_ROOT, "results", "phase2")
P1_DATA = os.path.join(REPO_ROOT, "results", "phase1")
PLOT_DIR = os.path.join(P2_DATA, "plots")
os.makedirs(PLOT_DIR, exist_ok=True)

CPU_LEVELS = [100, 80, 60, 40]
CPU_FRACTIONS = [1.0, 0.8, 0.6, 0.4]
CPU_MILLIS = [1000, 800, 600, 400]
BASELINE_P95 = None  # computed from data

# CFS data (from cfs_before/after files — hardcoded from measurements)
CFS_DATA = {
    100: {"throttle_ratio": 14.8, "throttled_frac": 0.015},
    80:  {"throttle_ratio": 98.0, "throttled_frac": 0.211},
    60:  {"throttle_ratio": 99.93, "throttled_frac": 0.397},
    40:  {"throttle_ratio": 99.95, "throttled_frac": 0.600},
}

# Phase 1 baseline data for cross-profile comparison
P1_DATA_TABLE = {
    "image-resize":    {"profile": "CPU-bound", "nonoc_p95": 4591, "oc_p95": 11156, "cpu_reduction": 2.47},
    "db-query":        {"profile": "I/O-bound", "nonoc_p95": 21,   "oc_p95": 28,    "cpu_reduction": 2.70},
    "log-filter":      {"profile": "Mixed",     "nonoc_p95": 17,   "oc_p95": 77,    "cpu_reduction": 2.43},
}

PROFILE_COLORS = {"CPU-bound": "#2563EB", "I/O-bound": "#059669", "Mixed": "#D97706"}

# ── Shared style ────────────────────────────────────────────────────────────

plt.rcParams.update({
    "font.family": "serif",
    "font.size": 13,
    "axes.labelsize": 15,
    "axes.titlesize": 16,
    "legend.fontsize": 11,
    "xtick.labelsize": 12,
    "ytick.labelsize": 12,
    "figure.dpi": 150,
    "savefig.dpi": 300,
    "savefig.pad_inches": 0.2,
    "axes.grid": True,
    "grid.alpha": 0.3,
    "grid.linestyle": "--",
})

# ── Data loading ────────────────────────────────────────────────────────────

def load_rep(level, rep):
    path = os.path.join(P2_DATA, f"image-resize_cpu{level}_rep{rep}.txt")
    with open(path) as f:
        return np.array([float(x) for x in f if x.strip()])

def compute_stats(vals):
    s = np.sort(vals)
    n = len(s)
    return {
        "n": n,
        "min": s[0], "max": s[-1],
        "mean": np.mean(s), "std": np.std(s),
        "p50": s[int(0.50 * n)],
        "p95": s[int(0.95 * n)],
        "p99": s[int(0.99 * n)],
    }

# Load all data
data = {}
for level in CPU_LEVELS:
    data[level] = {"reps": [], "all": None}
    all_vals = []
    for rep in [1, 2, 3]:
        vals = load_rep(level, rep)
        data[level]["reps"].append(vals)
        all_vals.extend(vals)
    data[level]["all"] = np.array(all_vals)
    data[level]["stats"] = compute_stats(data[level]["all"])
    data[level]["rep_stats"] = [compute_stats(r) for r in data[level]["reps"]]

BASELINE_P95 = data[100]["stats"]["p95"]

# ── Statistical analysis (printed to stdout) ────────────────────────────────

def print_analysis():
    print("=" * 70)
    print("PHASE 2 — STATISTICAL ANALYSIS")
    print("=" * 70)

    # Per-level summary
    print("\n--- Per-Level Summary ---")
    print(f"{'Level':>6} {'CPU(m)':>7} {'n':>5} {'Mean':>8} {'P50':>8} {'P95':>8} {'P99':>8} {'StdDev':>8} {'Deg':>6}")
    print("-" * 70)
    for level in CPU_LEVELS:
        s = data[level]["stats"]
        deg = s["p95"] / BASELINE_P95
        print(f"{level:>5}% {level*10:>6}m {s['n']:>5} {s['mean']:>8.1f} {s['p50']:>8.1f} "
              f"{s['p95']:>8.1f} {s['p99']:>8.1f} {s['std']:>8.1f} {deg:>5.2f}x")

    # Inter-rep variance
    print("\n--- Inter-Rep Variance (P95) ---")
    for level in CPU_LEVELS:
        p95s = [rs["p95"] for rs in data[level]["rep_stats"]]
        print(f"  cpu{level}: P95 = {p95s} | range = {max(p95s)-min(p95s):.0f} ms | cv = {np.std(p95s)/np.mean(p95s)*100:.2f}%")

    # Inverse-quota model fit
    print("\n--- Inverse-Quota Model Fit ---")
    measured = np.array([data[l]["stats"]["p95"] for l in CPU_LEVELS])
    predicted = np.array([BASELINE_P95 / f for f in CPU_FRACTIONS])
    residuals = measured - predicted
    ss_res = np.sum(residuals ** 2)
    ss_tot = np.sum((measured - np.mean(measured)) ** 2)
    r_squared = 1 - ss_res / ss_tot
    print(f"  Baseline P95 = {BASELINE_P95:.0f} ms")
    print(f"  R² = {r_squared:.6f}")
    print(f"  {'Level':>6} {'Measured':>10} {'Predicted':>10} {'Deviation':>10} {'Dev%':>8}")
    for i, level in enumerate(CPU_LEVELS):
        dev_pct = (measured[i] - predicted[i]) / predicted[i] * 100
        print(f"  {level:>5}% {measured[i]:>10.0f} {predicted[i]:>10.0f} {residuals[i]:>+10.0f} {dev_pct:>+7.1f}%")

    # Pearson correlation: throttle ratio vs degradation
    print("\n--- CFS Throttle Ratio vs Degradation Correlation ---")
    throttle = np.array([CFS_DATA[l]["throttle_ratio"] for l in CPU_LEVELS])
    degradation = measured / BASELINE_P95
    corr = np.corrcoef(throttle, degradation)[0, 1]
    print(f"  Pearson r = {corr:.4f}")
    print(f"  {'Level':>6} {'Throttle%':>10} {'Degradation':>12}")
    for i, level in enumerate(CPU_LEVELS):
        print(f"  {level:>5}% {throttle[i]:>9.1f}% {degradation[i]:>11.2f}x")

    print("\n" + "=" * 70)


# ── Plot P2.1: Degradation Curve with Inverse-Quota Model ───────────────────

def plot_degradation_curve():
    fig, ax = plt.subplots(figsize=(8, 5.5))

    # Measured data
    p95_means = [data[l]["stats"]["p95"] for l in CPU_LEVELS]
    p95_mins = [min(rs["p95"] for rs in data[l]["rep_stats"]) for l in CPU_LEVELS]
    p95_maxs = [max(rs["p95"] for rs in data[l]["rep_stats"]) for l in CPU_LEVELS]
    yerr_lo = [m - lo for m, lo in zip(p95_means, p95_mins)]
    yerr_hi = [hi - m for m, hi in zip(p95_means, p95_maxs)]

    ax.errorbar(CPU_LEVELS, p95_means, yerr=[yerr_lo, yerr_hi],
                fmt='o-', color='#2563EB', markersize=10, linewidth=2.5,
                capsize=6, capthick=2, label='Measured P95', zorder=5)

    # Inverse-quota model
    x_smooth = np.linspace(40, 100, 100)
    y_model = BASELINE_P95 / (x_smooth / 100)
    ax.plot(x_smooth, y_model, '--', color='#DC2626', linewidth=2,
            alpha=0.7, label='Predicted (P95 / x)')

    # Annotations with degradation ratios
    for level, p95 in zip(CPU_LEVELS, p95_means):
        deg = p95 / BASELINE_P95
        ax.annotate(f'{deg:.2f}x', xy=(level, p95),
                    xytext=(12, 8), textcoords='offset points',
                    fontsize=11, fontweight='bold', color='#1E3A5F')

    ax.set_xlabel('CPU Allocation (% of Non-OC)')
    ax.set_ylabel('P95 Latency (ms)')
    ax.set_title('image-resize Degradation Curve\nvs Inverse-Quota Model')
    ax.set_xticks(CPU_LEVELS)
    ax.set_xticklabels([f'{l}%\n({l*10}m)' for l in CPU_LEVELS])
    ax.invert_xaxis()
    ax.legend(loc='upper right', framealpha=0.9)
    ax.set_ylim(bottom=0)

    fig.tight_layout()
    path = os.path.join(PLOT_DIR, "fig6_degradation_curve.png")
    fig.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Plot P2.2: CFS Throttle Ratio vs Degradation ───────────────────────────

def plot_throttle_vs_degradation():
    fig, ax = plt.subplots(figsize=(7, 5))

    throttle = [CFS_DATA[l]["throttle_ratio"] for l in CPU_LEVELS]
    degradation = [data[l]["stats"]["p95"] / BASELINE_P95 for l in CPU_LEVELS]

    ax.scatter(throttle, degradation, s=200, c='#2563EB', edgecolors='#1E3A5F',
               linewidths=2, zorder=5)

    for i, level in enumerate(CPU_LEVELS):
        ax.annotate(f'{level}%\n({CPU_MILLIS[i]}m)',
                    xy=(throttle[i], degradation[i]),
                    xytext=(15, -5), textcoords='offset points',
                    fontsize=10, ha='left')

    # Highlight the phase transition
    ax.axvspan(0, 50, alpha=0.08, color='green', label='Low throttling')
    ax.axvspan(50, 100, alpha=0.08, color='red', label='Saturated throttling')
    ax.axvline(x=50, color='gray', linestyle=':', alpha=0.5)

    ax.set_xlabel('CFS Throttle Ratio (%)')
    ax.set_ylabel('P95 Degradation Ratio (vs 100%)')
    ax.set_title('CFS Throttling vs Latency Degradation\n(Phase Transition at ~15% → 98%)')
    ax.set_xlim(-5, 105)
    ax.set_ylim(bottom=0.5)
    ax.legend(loc='upper left', framealpha=0.9)

    fig.tight_layout()
    path = os.path.join(PLOT_DIR, "fig7_throttle_vs_degradation.png")
    fig.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Plot P2.3: Latency Distributions (Violin + Box) ────────────────────────

def plot_distributions():
    fig, ax = plt.subplots(figsize=(9, 5.5))

    positions = list(range(len(CPU_LEVELS)))
    all_data = [data[l]["all"] for l in CPU_LEVELS]
    colors = ['#93C5FD', '#60A5FA', '#3B82F6', '#1D4ED8']

    vp = ax.violinplot(all_data, positions=positions, showmeans=True,
                       showmedians=True, showextrema=False)
    for i, body in enumerate(vp['bodies']):
        body.set_facecolor(colors[i])
        body.set_alpha(0.6)
        body.set_edgecolor('#1E3A5F')
    vp['cmeans'].set_color('#DC2626')
    vp['cmeans'].set_linewidth(2)
    vp['cmedians'].set_color('#1E3A5F')
    vp['cmedians'].set_linewidth(2)

    # Overlay box plots
    bp = ax.boxplot(all_data, positions=positions, widths=0.15,
                    patch_artist=True, showfliers=True,
                    flierprops=dict(marker='o', markersize=3, alpha=0.4))
    for i, patch in enumerate(bp['boxes']):
        patch.set_facecolor(colors[i])
        patch.set_alpha(0.8)

    # Add P95 markers
    for i, level in enumerate(CPU_LEVELS):
        p95 = data[level]["stats"]["p95"]
        ax.plot(i, p95, 'r^', markersize=10, zorder=10)
        ax.annotate(f'P95={p95:.0f}', xy=(i, p95),
                    xytext=(10, 5), textcoords='offset points',
                    fontsize=9, color='#DC2626', fontweight='bold')

    ax.set_xticks(positions)
    ax.set_xticklabels([f'{l}%\n({l*10}m)' for l in CPU_LEVELS])
    ax.set_xlabel('CPU Allocation')
    ax.set_ylabel('Latency (ms)')
    ax.set_title('Latency Distribution at Each CPU Level\n(600 samples per level: 3 reps × 200)')

    # Legend
    from matplotlib.lines import Line2D
    legend_elements = [
        mpatches.Patch(facecolor='#60A5FA', alpha=0.6, label='Distribution (violin)'),
        Line2D([0], [0], color='#DC2626', linewidth=2, label='Mean'),
        Line2D([0], [0], color='#1E3A5F', linewidth=2, label='Median'),
        Line2D([0], [0], marker='^', color='#DC2626', linestyle='None', markersize=8, label='P95'),
    ]
    ax.legend(handles=legend_elements, loc='upper left', framealpha=0.9)

    fig.tight_layout()
    path = os.path.join(PLOT_DIR, "fig8_latency_distributions.png")
    fig.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Plot P2.4: Phase 1 Cross-Profile Comparison ────────────────────────────

def plot_cross_profile():
    fig, ax = plt.subplots(figsize=(8, 5))

    funcs = ["image-resize", "db-query", "log-filter"]
    profiles = [P1_DATA_TABLE[f]["profile"] for f in funcs]
    nonoc = [P1_DATA_TABLE[f]["nonoc_p95"] for f in funcs]
    oc = [P1_DATA_TABLE[f]["oc_p95"] for f in funcs]
    deg = [o / n for o, n in zip(oc, nonoc)]
    cpu_red = [P1_DATA_TABLE[f]["cpu_reduction"] for f in funcs]

    x = np.arange(len(funcs))
    width = 0.28

    bars1 = ax.bar(x - width, cpu_red, width, label='CPU Reduction',
                   color='#94A3B8', edgecolor='#475569', linewidth=1.2)
    bars2 = ax.bar(x, deg, width, label='P95 Degradation',
                   color=[PROFILE_COLORS[p] for p in profiles],
                   edgecolor='#1E3A5F', linewidth=1.2)
    bars3 = ax.bar(x + width, [o / n for o, n in zip(
                   [P1_DATA_TABLE[f].get("oc_mean", o) for f, o in zip(funcs, oc)],
                   [P1_DATA_TABLE[f].get("nonoc_mean", n) for f, n in zip(funcs, nonoc)])],
                   width, label='Mean Degradation',
                   color=[PROFILE_COLORS[p] for p in profiles],
                   alpha=0.5, edgecolor='#1E3A5F', linewidth=1.2)

    # Value labels
    for bar, val in zip(bars1, cpu_red):
        ax.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 0.05,
                f'{val:.1f}x', ha='center', fontsize=10, fontweight='bold')
    for bar, val in zip(bars2, deg):
        ax.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 0.05,
                f'{val:.1f}x', ha='center', fontsize=10, fontweight='bold')

    ax.set_xticks(x)
    ax.set_xticklabels([f'{f}\n({p})' for f, p in zip(funcs, profiles)])
    ax.set_ylabel('Ratio')
    ax.set_title('Phase 1: Profile-Dependent Degradation\nat Default Overcommitment Level')
    ax.legend(loc='upper left', framealpha=0.9)
    ax.set_ylim(0, 5.5)
    ax.axhline(y=1.0, color='gray', linestyle=':', alpha=0.5, linewidth=1)

    fig.tight_layout()
    path = os.path.join(PLOT_DIR, "fig9_cross_profile_comparison.png")
    fig.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Plot P2.5: Combined Degradation + CFS Throttle (Dual Axis) ─────────────

def plot_combined_dual_axis():
    fig, ax1 = plt.subplots(figsize=(8, 5.5))
    ax2 = ax1.twinx()

    # Degradation curve on left axis
    p95_means = [data[l]["stats"]["p95"] for l in CPU_LEVELS]
    degradation = [p / BASELINE_P95 for p in p95_means]
    predicted = [1.0 / f for f in CPU_FRACTIONS]

    line1, = ax1.plot(CPU_LEVELS, degradation, 'o-', color='#2563EB',
                      markersize=10, linewidth=2.5, label='Measured Degradation', zorder=5)
    line1p, = ax1.plot(CPU_LEVELS, predicted, 's--', color='#2563EB',
                       markersize=6, linewidth=1.5, alpha=0.5, label='Predicted (1/x)')

    # CFS throttle ratio on right axis
    throttle = [CFS_DATA[l]["throttle_ratio"] for l in CPU_LEVELS]
    line2, = ax2.plot(CPU_LEVELS, throttle, 'D-', color='#DC2626',
                      markersize=9, linewidth=2.5, label='CFS Throttle Ratio', zorder=4)

    ax1.set_xlabel('CPU Allocation (% of Non-OC)')
    ax1.set_ylabel('P95 Degradation Ratio', color='#2563EB')
    ax2.set_ylabel('CFS Throttle Ratio (%)', color='#DC2626')
    ax1.set_xticks(CPU_LEVELS)
    ax1.set_xticklabels([f'{l}%\n({l*10}m)' for l in CPU_LEVELS])
    ax1.invert_xaxis()
    ax1.set_ylim(bottom=0)
    ax2.set_ylim(0, 105)

    ax1.tick_params(axis='y', labelcolor='#2563EB')
    ax2.tick_params(axis='y', labelcolor='#DC2626')

    # Combined legend
    lines = [line1, line1p, line2]
    labels = [l.get_label() for l in lines]
    ax1.legend(lines, labels, loc='center left', framealpha=0.9)

    ax1.set_title('Degradation Curve + CFS Throttle Ratio\n(image-resize, CPU-bound)')

    fig.tight_layout()
    path = os.path.join(PLOT_DIR, "fig10_combined_degradation_throttle.png")
    fig.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Plot P2.6: Rep-Level Consistency Heatmap ────────────────────────────────

def plot_rep_heatmap():
    fig, ax = plt.subplots(figsize=(7, 4.5))

    matrix = np.zeros((len(CPU_LEVELS), 3))
    for i, level in enumerate(CPU_LEVELS):
        for j in range(3):
            matrix[i, j] = data[level]["rep_stats"][j]["p95"]

    im = ax.imshow(matrix, cmap='YlOrRd', aspect='auto')
    cbar = fig.colorbar(im, ax=ax, label='P95 Latency (ms)')

    ax.set_xticks(range(3))
    ax.set_xticklabels(['Rep 1', 'Rep 2', 'Rep 3'])
    ax.set_yticks(range(len(CPU_LEVELS)))
    ax.set_yticklabels([f'{l}% ({l*10}m)' for l in CPU_LEVELS])
    ax.set_xlabel('Repetition')
    ax.set_ylabel('CPU Level')
    ax.set_title('P95 Latency Consistency Across Repetitions')

    # Annotate cells
    for i in range(len(CPU_LEVELS)):
        for j in range(3):
            val = matrix[i, j]
            color = 'white' if val > (matrix.max() + matrix.min()) / 2 else 'black'
            ax.text(j, i, f'{val:.0f}', ha='center', va='center',
                    fontsize=11, fontweight='bold', color=color)

    fig.tight_layout()
    path = os.path.join(PLOT_DIR, "fig11_rep_consistency_heatmap.png")
    fig.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Main ────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    print_analysis()

    print("\nGenerating Phase 2 plots...")
    plot_degradation_curve()      # Fig 6
    plot_throttle_vs_degradation() # Fig 7
    plot_distributions()          # Fig 8
    plot_cross_profile()          # Fig 9
    plot_combined_dual_axis()     # Fig 10
    plot_rep_heatmap()            # Fig 11

    print(f"\nAll plots saved to: {PLOT_DIR}")
    print("Done.")
