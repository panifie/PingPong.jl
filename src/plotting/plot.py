from jinja2.environment import load_extensions
import pyecharts as pyec
from typing import List, Sequence, Union, Tuple, Dict
from os import getcwd
from os.path import dirname
from pathlib import Path

from pyecharts import options as opts
import pyecharts
from pyecharts.charts.chart import Chart
from pyecharts.commons.utils import JsCode
from pyecharts.charts import Kline, Line, Bar, Grid, HeatMap
from pyecharts import faker

ECHART_OHLC_COLS = ["open", "close", "low", "high"]
CHART_WIDTH = "1920px"
CHART_HEIGHT = "1080px"
INIT_OPTS = opts.InitOpts(width="1400px", height="800px")


def render(chart):
    chart_path = str(getcwd() / Path("render.html"))
    print(f"Writing chart to {chart_path}")
    chart.render(chart_path)


def volume_bar(x, y):
    b = Bar(init_opts=INIT_OPTS)
    b.add_xaxis(xaxis_data=x)
    b.add_yaxis(
        series_name="",
        # xaxis_index=1,
        # yaxis_index=1,
        y_axis=y,
        label_opts=opts.LabelOpts(is_show=False),
    )
    b.set_global_opts(
        xaxis_opts=opts.AxisOpts(
            type_="category",
            axislabel_opts=opts.LabelOpts(is_show=False),
            boundary_gap=True,
            axisline_opts=opts.AxisLineOpts(is_on_zero=False),
            axistick_opts=opts.AxisTickOpts(is_show=False),
            splitline_opts=opts.SplitLineOpts(is_show=False),
            split_number=10,
            # grid_index=0,
        ),
        yaxis_opts=opts.AxisOpts(
            is_scale=True,
            splitarea_opts=opts.SplitAreaOpts(
                is_show=True, areastyle_opts=opts.AreaStyleOpts(opacity=1)
            ),
            axislabel_opts=opts.LabelOpts(is_show=False),
        ),
        legend_opts=opts.LegendOpts(is_show=True, pos_left=0),
    )
    return b


def ind_bar(x, y, name="", grid_idx=1, legend_pos={}):
    b = Bar(init_opts=INIT_OPTS)
    b.add_xaxis(xaxis_data=x)
    b.add_yaxis(
        series_name=name,
        y_axis=y,
        # xaxis_index=grid_idx,
        # yaxis_index=grid_idx,
        label_opts=opts.LabelOpts(is_show=False),
    )
    b.set_global_opts(
        xaxis_opts=opts.AxisOpts(
            type_="category",
            axislabel_opts=opts.LabelOpts(is_show=False),
            boundary_gap=True,
            axisline_opts=opts.AxisLineOpts(is_on_zero=False),
            axistick_opts=opts.AxisTickOpts(is_show=False),
            splitline_opts=opts.SplitLineOpts(is_show=False),
            split_number=10,
            # grid_index=grid_idx,
        ),
        yaxis_opts=opts.AxisOpts(
            grid_index=grid_idx,
            is_scale=True,
            splitarea_opts=opts.SplitAreaOpts(
                is_show=True, areastyle_opts=opts.AreaStyleOpts(opacity=1)
            ),
            axislabel_opts=opts.LabelOpts(is_show=False),
        ),
        legend_opts=opts.LegendOpts(is_show=True, **legend_pos),
    )
    return b


def ind_line(x, y, name="", grid_idx=1, legend_pos={}):
    l = Line(init_opts=INIT_OPTS)
    l.add_xaxis(xaxis_data=x)
    l.add_yaxis(
        series_name=name,
        xaxis_index=grid_idx,
        yaxis_index=grid_idx,
        y_axis=y,
        is_smooth=True,
        is_hover_animation=False,
        linestyle_opts=opts.LineStyleOpts(opacity=0.5),
        label_opts=opts.LabelOpts(is_show=False),
    )
    l.set_global_opts(
        xaxis_opts=opts.AxisOpts(
            type_="category",
            grid_index=grid_idx,
            axislabel_opts=opts.LabelOpts(is_show=False),
        ),
        yaxis_opts=opts.AxisOpts(
            grid_index=grid_idx,
            axisline_opts=opts.AxisLineOpts(is_on_zero=False),
            axistick_opts=opts.AxisTickOpts(is_show=False),
            splitline_opts=opts.SplitLineOpts(is_show=False),
            axislabel_opts=opts.LabelOpts(is_show=True),
        ),
        legend_opts=opts.LegendOpts(is_show=True, **legend_pos),
    )
    return l


def kline_chart(x, y, name=""):
    k = Kline(init_opts=opts.InitOpts(width=CHART_WIDTH, height=CHART_HEIGHT))
    k.add_xaxis(xaxis_data=x)
    k.add_yaxis(
        series_name=name,
        y_axis=y,
        itemstyle_opts=opts.ItemStyleOpts(
            color="#14b143",
            color0="#ef232a",
            border_color="#14b143",
            border_color0="#ef232a",
        ),
        # markpoint_opts=opts.MarkPointOpts(
        #     data=[
        #         opts.MarkPointItem(type_="max", name="???"),
        #         opts.MarkPointItem(type_="min", name="???"),
        #     ]
        # ),
        # markline_opts=opts.MarkLineOpts(
        #     label_opts=opts.LabelOpts(
        #         position="middle", color="blue", font_size=15
        #     ),
        #     data=[],
        #     symbol=["circle", "none"],
        # ),
    )
    # .set_series_opts(
    #     markarea_opts=opts.MarkAreaOpts(is_silent=True, data=[])
    # )
    return k


def k_chart_global_opts(chart, name, x_idx, grid_idx=0, y_idx=[]):
    if not y_idx:
        y_idx.extend(x_idx)

    chart.set_global_opts(
        legend_opts=opts.LegendOpts(is_show=True),
        title_opts=opts.TitleOpts(title=name, pos_left="0"),
        xaxis_opts=opts.AxisOpts(grid_index=grid_idx),
        yaxis_opts=opts.AxisOpts(
            grid_index=grid_idx,
            is_scale=True,
            splitline_opts=opts.SplitLineOpts(is_show=True),
            splitarea_opts=opts.SplitAreaOpts(
                is_show=True, areastyle_opts=opts.AreaStyleOpts(opacity=1)
            ),
        ),
        tooltip_opts=opts.TooltipOpts(
            trigger="axis",
            axis_pointer_type="cross",
            background_color="rgba(245, 245, 245, 0.8)",
            border_width=1,
            border_color="#ccc",
            textstyle_opts=opts.TextStyleOpts(color="#000"),
        ),
        visualmap_opts=opts.VisualMapOpts(
            is_show=False,
            dimension=2,
            series_index=5,
            is_piecewise=True,
            pieces=[
                {"value": 1, "color": "#00da3c"},
                {"value": -1, "color": "#ec0000"},
            ],
        ),
        axispointer_opts=opts.AxisPointerOpts(
            is_show=True,
            link=[{"xAxisIndex": "all"}],
            label=opts.LabelOpts(background_color="#777"),
        ),
        brush_opts=opts.BrushOpts(
            x_axis_index="all",
            brush_link="all",
            out_of_brush={"colorAlpha": 0.1},
            brush_type="lineX",
        ),
        datazoom_opts=[
            opts.DataZoomOpts(
                xaxis_index=x_idx,
                is_show=False,
                type_="inside",
                range_start=98,
                range_end=100,
            ),
            opts.DataZoomOpts(
                xaxis_index=y_idx,
                is_show=True,
                type_="slider",
                pos_top="90%",
                range_start=98,
                range_end=100,
            ),
        ],
    )

def grid(dates, ohlc, inds: Dict[str, Tuple[str, List]] = {}, name="OHLCV"):
    """
    `inds`: Every indicator should specify its plot type. Eg. ("bar", [...])
    """

    global INIT_OPTS
    INIT_OPTS = opts.InitOpts(width="1400px", height="800px")
    g = Grid(init_opts=INIT_OPTS)
    k_chart = kline_chart(dates, ohlc, name=name)
    v_bar = volume_bar(dates, inds["volume"][1])

    iinds = inds.copy()
    del iinds["volume"]

    ic = None
    legend_pos = {"pos_left": 0, "pos_top": 0}
    ind_charts = []
    for (name, (plot_type, vec)) in iinds.items():
        legend_pos["pos_top"] += 25
        if plot_type == "line":
            ic = plotsfn[plot_type](dates, vec, name, legend_pos=legend_pos, grid_idx=0)
            k_chart = k_chart.overlap(ic)
        else:
            ic = plotsfn[plot_type](dates, vec, name, legend_pos=legend_pos, grid_idx=2)
            ind_charts.append(ic)

    k_chart.set_global_opts(
        tooltip_opts=opts.TooltipOpts(
            trigger="axis",
            axis_pointer_type="cross",
            background_color="rgba(245, 245, 245, 0.8)",
            border_width=1,
            border_color="#ccc",
            textstyle_opts=opts.TextStyleOpts(color="#000"),
        )
    )
    # NOTE: Options need to be applied before adding charts to the grid (They are copied?)
    zoom_idx = list(range(2 + len(ind_charts))) if len(ind_charts) else [0, 1]
    k_chart_global_opts(k_chart, "ohlc", x_idx=zoom_idx, grid_idx=0)
    # NOTE: The order is importat for correct application of global options (like zoom)
    g.add(k_chart, grid_opts=opts.GridOpts(height="49%"))
    g.add(v_bar, grid_opts=opts.GridOpts(height="9%", pos_top="70%"))

    for ic in ind_charts:
        g.add(ic, grid_opts=opts.GridOpts(height="9%", pos_top="80%"))

    render(g)


def scatter3d(data: list, name="", x="x", y="y", z="z",):
    sc = pyecharts.charts.Scatter3D(init_opts=INIT_OPTS)
    sc.add(
        series_name=name,
        data=data,
        xaxis3d_opts=opts.Axis3DOpts(name=x, type_="value"),
        yaxis3d_opts=opts.Axis3DOpts(name=y, type_="value"),
        zaxis3d_opts=opts.Axis3DOpts(name=z, type_="value"),
        grid3d_opts=opts.Grid3DOpts(width=100, height=100, depth=100),
    )
    sc.set_global_opts(
        visualmap_opts=[
            # opts.VisualMapOpts(
            #     type_="size",
            #     is_calculable=True,
            #     is_show=True,
            #     # range_size=range(1, 200),
            #     dimension=2,
            #     range_opacity=0.2
            # ),
            opts.VisualMapOpts(
                type_="color", is_calculable=True, is_show=True, dimension=1
            ),
        ],
    )
    render(sc)

def heatmap(x, y, title="", y_name="", y_labels=""):
    ht = HeatMap()
    ht.add_xaxis(x)
    ht.add_yaxis(y_name, y_labels, y)
    ht.set_global_opts(
        title_opts=opts.TitleOpts(title=title),
        visualmap_opts=opts.VisualMapOpts(),
    )
    render(ht)

plotsfn = {"bar": ind_bar, "line": ind_line}
