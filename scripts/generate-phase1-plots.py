#!/usr/bin/env python3
"""generate-phase1-plots.py — Generate publication-quality plots from Phase 1 latency data.

Produces 5 figures matching the Golgi paper's visual style:
  1. CDF plot — all 6 functions overlaid (paper Fig. 5 style)
  2. CDF per function — Non-OC vs OC with SLO line (3 subplots)
  3. P95 bar chart — grouped bars with degradation ratios (paper Fig. 7 style)
  4. Box plots — latency distribution showing bimodal behavior
  5. Degradation ratio bar chart — visualizing the core hypothesis

Usage: py scripts/generate-phase1-plots.py
Output: results/phase1/plots/*.png
"""

import os
import numpy as np
import matplotlib
matplotlib.use("Agg")  # non-interactive backend
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter

# ── Configuration ───────────────────────────────────────────────────────────

DATA_DIR = os.path.join(os.path.dirname(__file__), "..", "results", "phase1")
PLOT_DIR = os.path.join(DATA_DIR, "plots")
os.makedirs(PLOT_DIR, exist_ok=True)

FUNCTIONS = {
    "image-resize":    {"label": "image-resize",    "profile": "CPU-bound",  "variant": "Non-OC", "color": "#2563EB", "ls": "-"},
    "image-resize-oc": {"label": "image-resize-oc", "profile": "CPU-bound",  "variant": "OC",     "color": "#2563EB", "ls": "--"},
    "db-query":        {"label": "db-query",         "profile": "I/O-bound", "variant": "Non-OC", "color": "#059669", "ls": "-"},
    "db-query-oc":     {"label": "db-query-oc",      "profile": "I/O-bound", "variant": "OC",     "color": "#059669", "ls": "--"},
    "log-filter":      {"label": "log-filter",       "profile": "Mixed",     "variant": "Non-OC", "color": "#D97706", "ls": "-"},
    "log-filter-oc":   {"label": "log-filter-oc",    "profile": "Mixed",     "variant": "OC",     "color": "#D97706", "ls": "--"},
}

NON_OC_FUNCS = ["image-resize", "db-query", "log-filter"]
OC_FUNCS = ["image-resize-oc", "db-query-oc", "log-filter-oc"]
PAIRS = list(zip(NON_OC_FUNCS, OC_FUNCS))

PROFILE_COLORS = {"CPU-bound": "#2563EB", "I/O-bound": "#059669", "Mixed": "#D97706"}
PROFILE_LABELS = {"image-resize": "CPU-bound", "db-query": "I/O-bound", "log-filter": "Mixed"}

# ── Shared style ────────────────────────────────────────────────────────────

plt.rcParams.update({
    "font.family": "serif",
    "font.size": 11,
    "axes.labelsize": 12,
    "axes.titlesize": 13,
    "legend.fontsize": 9,
    "xtick.labelsize": 10,
    "ytick.labelsize": 10,
    "figure.dpi": 150,
    "savefig.dpi": 300,
    "savefig.pad_inches": 0.1,
    "axes.grid": True,
    "grid.alpha": 0.3,
    "grid.linestyle": "--",
})


# ── Data loading ────────────────────────────────────────────────────────────

def load_latencies(func_name):
    path = os.path.join(DATA_DIR, f"{func_name}_latencies.txt")
    with open(path) as f:
        return np.array([int(line.strip()) for line in f if line.strip()])


def compute_stats(vals):
    s = np.sort(vals)
    n = len(s)
    return {
        "min": s[0], "max": s[-1],
        "mean": np.mean(s), "std": np.std(s),
        "p50": s[int(0.50 * n)],
        "p95": s[int(0.95 * n)],
        "p99": s[int(0.99 * n)],
    }


data = {name: load_latencies(name) for name in FUNCTIONS}
stats = {name: compute_stats(v) for name, v in data.items()}

# SLO thresholds = Non-OC P95
SLO = {func: stats[func]["p95"] for func in NON_OC_FUNCS}


# ── Plot 1: CDF — Fast functions (db-query, log-filter) ────────────────────

def plot_cdf_fast():
    """CDF of db-query and log-filter (Non-OC and OC variants)."""
    fig, ax = plt.subplots(figsize=(8, 5))

    for func in ["db-query", "db-query-oc", "log-filter", "log-filter-oc"]:
        s = np.sort(data[func])
        cdf = np.arange(1, len(s) + 1) / len(s)
        cfg = FUNCTIONS[func]
        lw = 2.0 if cfg["variant"] == "Non-OC" else 1.5
        ax.plot(s, cdf, label=f'{cfg["label"]} ({cfg["profile"]}, {cfg["variant"]})',
                color=cfg["color"], linestyle=cfg["ls"], linewidth=lw)

    # SLO lines
    for func in ["db-query", "log-filter"]:
        ax.axvline(SLO[func], color=FUNCTIONS[func]["color"], linestyle=":",
                   alpha=0.6, linewidth=1)
        ax.text(SLO[func] + 0.5, 0.05, f'SLO={SLO[func]}ms',
                color=FUNCTIONS[func]["color"], fontsize=8, rotation=90, va="bottom")

    # P95 reference line
    ax.axhline(0.95, color="gray", linestyle=":", alpha=0.5, linewidth=1)
    ax.text(95, 0.955, "P95", color="gray", fontsize=8)

    ax.set_xlabel("Latency (ms)")
    ax.set_ylabel("CDF")
    ax.set_title("Latency CDF — Fast Functions (db-query, log-filter)")
    ax.legend(loc="lower right")
    ax.set_ylim(0, 1.02)
    ax.set_xlim(10, 105)

    fig.savefig(os.path.join(PLOT_DIR, "fig1_cdf_fast_functions.png"))
    plt.close(fig)
    print("  [1/5] fig1_cdf_fast_functions.png")


# ── Plot 2: CDF per function — Non-OC vs OC with SLO line (3 subplots) ────

def plot_cdf_per_function():
    """Three-panel CDF: one per function, Non-OC vs OC with SLO threshold."""
    fig, axes = plt.subplots(1, 3, figsize=(16, 5))

    for idx, (non_oc, oc) in enumerate(PAIRS):
        ax = axes[idx]
        profile = PROFILE_LABELS[non_oc]
        color = PROFILE_COLORS[profile]
        slo_val = SLO[non_oc]

        # Non-OC CDF
        s1 = np.sort(data[non_oc])
        cdf1 = np.arange(1, len(s1) + 1) / len(s1)
        ax.plot(s1, cdf1, color=color, linestyle="-", linewidth=2.0,
                label=f"{non_oc} (Non-OC)")

        # OC CDF
        s2 = np.sort(data[oc])
        cdf2 = np.arange(1, len(s2) + 1) / len(s2)
        ax.plot(s2, cdf2, color=color, linestyle="--", linewidth=1.5,
                label=f"{oc} (OC)")

        # SLO line
        ax.axvline(slo_val, color="red", linestyle=":", linewidth=1.5, alpha=0.7)
        ax.text(slo_val, 0.02, f" SLO={slo_val}ms", color="red", fontsize=8,
                ha="left", va="bottom")

        # P95 reference
        ax.axhline(0.95, color="gray", linestyle=":", alpha=0.4, linewidth=1)

        # Shade the SLO violation region
        ax.axvspan(slo_val, ax.get_xlim()[1] if idx > 0 else s2[-1] * 1.05,
                   alpha=0.08, color="red")

        ax.set_xlabel("Latency (ms)")
        if idx == 0:
            ax.set_ylabel("CDF")
        ax.set_title(f"{non_oc} ({profile})")
        ax.legend(loc="lower right", fontsize=8)
        ax.set_ylim(0, 1.02)

    fig.suptitle("Latency CDF — Non-OC vs OC per Function (with SLO Threshold)",
                 fontsize=14, y=1.02)
    fig.tight_layout()
    fig.savefig(os.path.join(PLOT_DIR, "fig2_cdf_per_function.png"))
    plt.close(fig)
    print("  [2/5] fig2_cdf_per_function.png")


# ── Plot 3: P95 bar chart — grouped bars with degradation annotations ──────

def plot_p95_bar_chart():
    """Grouped bar chart of P95 latency: Non-OC vs OC, with degradation ratio."""
    fig, axes = plt.subplots(1, 2, figsize=(14, 5),
                              gridspec_kw={"width_ratios": [1, 2.5]})

    # Left panel: image-resize (large values)
    ax_left = axes[0]
    func = "image-resize"
    non_oc_p95 = stats[func]["p95"]
    oc_p95 = stats[func + "-oc"]["p95"]
    ratio = oc_p95 / non_oc_p95

    x = np.array([0])
    w = 0.35
    bars1 = ax_left.bar(x - w/2, [non_oc_p95], w, label="Non-OC", color="#2563EB", alpha=0.85)
    bars2 = ax_left.bar(x + w/2, [oc_p95], w, label="OC", color="#2563EB", alpha=0.45,
                        edgecolor="#2563EB", linewidth=1.5)

    ax_left.bar_label(bars1, fmt="%.0f ms", fontsize=9, padding=3)
    ax_left.bar_label(bars2, fmt="%.0f ms", fontsize=9, padding=3)

    # Degradation ratio annotation
    mid_y = (non_oc_p95 + oc_p95) / 2
    ax_left.annotate(f"{ratio:.1f}x", xy=(w/2 + 0.02, oc_p95),
                     fontsize=11, fontweight="bold", color="#DC2626",
                     ha="left", va="bottom")

    ax_left.set_xticks(x)
    ax_left.set_xticklabels(["image-resize\n(CPU-bound)"])
    ax_left.set_ylabel("P95 Latency (ms)")
    ax_left.set_title("CPU-bound Function")
    ax_left.legend(fontsize=9)

    # Right panel: db-query and log-filter (small values)
    ax_right = axes[1]
    func_names = ["db-query", "log-filter"]
    profiles = ["I/O-bound", "Mixed"]
    colors = ["#059669", "#D97706"]

    x = np.arange(len(func_names))
    non_oc_vals = [stats[f]["p95"] for f in func_names]
    oc_vals = [stats[f + "-oc"]["p95"] for f in func_names]
    ratios = [oc / non_oc for non_oc, oc in zip(non_oc_vals, oc_vals)]

    for i, (f, c) in enumerate(zip(func_names, colors)):
        b1 = ax_right.bar(i - w/2, non_oc_vals[i], w, color=c, alpha=0.85,
                          label="Non-OC" if i == 0 else None)
        b2 = ax_right.bar(i + w/2, oc_vals[i], w, color=c, alpha=0.45,
                          edgecolor=c, linewidth=1.5,
                          label="OC" if i == 0 else None)
        ax_right.bar_label(b1, fmt="%.0f ms", fontsize=9, padding=3)
        ax_right.bar_label(b2, fmt="%.0f ms", fontsize=9, padding=3)

        ax_right.annotate(f"{ratios[i]:.1f}x", xy=(i + w/2 + 0.02, oc_vals[i]),
                         fontsize=11, fontweight="bold", color="#DC2626",
                         ha="left", va="bottom")

    ax_right.set_xticks(x)
    ax_right.set_xticklabels([f"{f}\n({p})" for f, p in zip(func_names, profiles)])
    ax_right.set_ylabel("P95 Latency (ms)")
    ax_right.set_title("Fast Functions (I/O-bound, Mixed)")
    ax_right.legend(fontsize=9)

    fig.suptitle("P95 Latency: Non-OC vs OC (with Degradation Ratio)",
                 fontsize=14, y=1.02)
    fig.tight_layout()
    fig.savefig(os.path.join(PLOT_DIR, "fig3_p95_bar_chart.png"))
    plt.close(fig)
    print("  [3/5] fig3_p95_bar_chart.png")


# ── Plot 4: Box plots — showing distribution shape ─────────────────────────

def plot_box_plots():
    """Box plots for all 6 functions, showing distribution shape and outliers."""
    fig, axes = plt.subplots(1, 2, figsize=(14, 5),
                              gridspec_kw={"width_ratios": [1, 2.5]})

    # Left panel: image-resize variants (large latencies)
    ax_left = axes[0]
    bp1 = ax_left.boxplot(
        [data["image-resize"], data["image-resize-oc"]],
        labels=["image-resize\n(Non-OC)", "image-resize-oc\n(OC)"],
        patch_artist=True, widths=0.5,
        boxprops=dict(facecolor="#2563EB", alpha=0.3),
        medianprops=dict(color="#1E40AF", linewidth=2),
        whiskerprops=dict(color="#2563EB"),
        capprops=dict(color="#2563EB"),
        flierprops=dict(marker="o", markerfacecolor="#2563EB", markersize=4, alpha=0.5),
    )
    # Color OC box differently
    bp1["boxes"][1].set_facecolor("#93C5FD")
    bp1["boxes"][1].set_alpha(0.4)

    # SLO line
    ax_left.axhline(SLO["image-resize"], color="red", linestyle=":", linewidth=1.5, alpha=0.7)
    ax_left.text(2.55, SLO["image-resize"], f'SLO={SLO["image-resize"]}ms',
                 color="red", fontsize=8, va="center")

    ax_left.set_ylabel("Latency (ms)")
    ax_left.set_title("image-resize (CPU-bound)")

    # Right panel: fast functions
    ax_right = axes[1]
    fast_data = [
        data["db-query"], data["db-query-oc"],
        data["log-filter"], data["log-filter-oc"],
    ]
    fast_labels = [
        "db-query\n(Non-OC)", "db-query\n(OC)",
        "log-filter\n(Non-OC)", "log-filter\n(OC)",
    ]
    fast_colors = ["#059669", "#059669", "#D97706", "#D97706"]
    fast_alphas = [0.3, 0.15, 0.3, 0.15]

    bp2 = ax_right.boxplot(
        fast_data, labels=fast_labels, patch_artist=True, widths=0.5,
        medianprops=dict(linewidth=2),
        flierprops=dict(marker="o", markersize=4, alpha=0.5),
    )
    for i, (box, color, alpha) in enumerate(zip(bp2["boxes"], fast_colors, fast_alphas)):
        box.set_facecolor(color)
        box.set_alpha(alpha)
        bp2["medians"][i].set_color(color)
        bp2["whiskers"][2*i].set_color(color)
        bp2["whiskers"][2*i+1].set_color(color)
        bp2["caps"][2*i].set_color(color)
        bp2["caps"][2*i+1].set_color(color)
        for flier in bp2["fliers"]:
            flier.set_markerfacecolor(color)

    # SLO lines
    ax_right.axhline(SLO["db-query"], color="#059669", linestyle=":", linewidth=1, alpha=0.6)
    ax_right.axhline(SLO["log-filter"], color="#D97706", linestyle=":", linewidth=1, alpha=0.6)
    ax_right.text(4.55, SLO["db-query"], f'SLO={SLO["db-query"]}ms', color="#059669", fontsize=8, va="center")
    ax_right.text(4.55, SLO["log-filter"], f'SLO={SLO["log-filter"]}ms', color="#D97706", fontsize=8, va="center")

    ax_right.set_ylabel("Latency (ms)")
    ax_right.set_title("db-query (I/O-bound) & log-filter (Mixed)")

    fig.suptitle("Latency Distribution — Box Plots (200 requests each)",
                 fontsize=14, y=1.02)
    fig.tight_layout()
    fig.savefig(os.path.join(PLOT_DIR, "fig4_box_plots.png"))
    plt.close(fig)
    print("  [4/5] fig4_box_plots.png")


# ── Plot 5: Degradation ratio bar chart ─────────────────────────────────────

def plot_degradation_ratios():
    """Bar chart of P95 degradation ratios with CPU reduction reference line."""
    fig, ax = plt.subplots(figsize=(8, 5))

    func_names = ["image-resize", "db-query", "log-filter"]
    profiles = ["CPU-bound", "I/O-bound", "Mixed"]
    colors = ["#2563EB", "#059669", "#D97706"]

    # Degradation ratios
    p95_ratios = [stats[f + "-oc"]["p95"] / stats[f]["p95"] for f in func_names]
    mean_ratios = [stats[f + "-oc"]["mean"] / stats[f]["mean"] for f in func_names]

    # CPU reduction ratios
    cpu_non_oc = [1000, 500, 500]
    cpu_oc = [405, 185, 206]
    cpu_ratios = [n / o for n, o in zip(cpu_non_oc, cpu_oc)]

    x = np.arange(len(func_names))
    w = 0.25

    bars1 = ax.bar(x - w, p95_ratios, w, label="P95 Latency Ratio (OC/Non-OC)",
                   color=[c for c in colors], alpha=0.85)
    bars2 = ax.bar(x, mean_ratios, w, label="Mean Latency Ratio (OC/Non-OC)",
                   color=[c for c in colors], alpha=0.45,
                   edgecolor=[c for c in colors], linewidth=1.5)
    bars3 = ax.bar(x + w, cpu_ratios, w, label="CPU Reduction Ratio (Non-OC/OC)",
                   color="gray", alpha=0.3, edgecolor="gray", linewidth=1.5)

    # Value labels
    for bars in [bars1, bars2, bars3]:
        ax.bar_label(bars, fmt="%.1fx", fontsize=9, padding=3)

    # Reference line at 1.0 (no degradation)
    ax.axhline(1.0, color="black", linestyle="-", linewidth=0.5, alpha=0.3)

    ax.set_xticks(x)
    ax.set_xticklabels([f"{f}\n({p})" for f, p in zip(func_names, profiles)])
    ax.set_ylabel("Ratio")
    ax.set_title("Overcommitment Impact — Degradation Ratios by Function Profile")
    ax.legend(loc="upper left", fontsize=9)
    ax.set_ylim(0, max(p95_ratios + cpu_ratios) * 1.25)

    # Annotation box
    textstr = ("CPU-bound: degradation matches CPU cut (2.4x ≈ 2.5x)\n"
               "I/O-bound: minimal degradation despite 2.7x CPU cut\n"
               "Mixed: disproportionate degradation from CFS throttling")
    props = dict(boxstyle="round,pad=0.5", facecolor="lightyellow", alpha=0.8)
    ax.text(0.98, 0.98, textstr, transform=ax.transAxes, fontsize=8,
            verticalalignment="top", horizontalalignment="right", bbox=props)

    fig.savefig(os.path.join(PLOT_DIR, "fig5_degradation_ratios.png"))
    plt.close(fig)
    print("  [5/5] fig5_degradation_ratios.png")


# ── Main ────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    print(f"Data directory: {os.path.abspath(DATA_DIR)}")
    print(f"Plot directory: {os.path.abspath(PLOT_DIR)}")
    print()

    # Print stats summary
    print("Latency Statistics (200 requests each):")
    print(f"{'Function':<20} {'P50':>6} {'P95':>6} {'P99':>6} {'Mean':>8} {'StdDev':>8}")
    print("-" * 60)
    for name in FUNCTIONS:
        s = stats[name]
        print(f"{name:<20} {s['p50']:>5}ms {s['p95']:>5}ms {s['p99']:>5}ms "
              f"{s['mean']:>7.1f}ms {s['std']:>7.1f}ms")
    print()

    print("SLO Thresholds (Non-OC P95):")
    for func in NON_OC_FUNCS:
        print(f"  SLO_{func.replace('-', '_')} = {SLO[func]} ms")
    print()

    print("Generating plots...")
    plot_cdf_fast()
    plot_cdf_per_function()
    plot_p95_bar_chart()
    plot_box_plots()
    plot_degradation_ratios()

    print(f"\nAll plots saved to: {os.path.abspath(PLOT_DIR)}")
