from jinja2.environment import load_extensions
import pyecharts as pyec
from typing import List, Sequence, Union, Tuple, Dict

from pyecharts import options as opts
import pyecharts
from pyecharts.charts.chart import Chart
from pyecharts.commons.utils import JsCode
from pyecharts.charts import Kline, Line, Bar, Grid

ECHART_OHLC_COLS = ["open", "close", "low", "high"]


def volume_bar(x, y):
    b = Bar(init_opts=INIT_OPTS)
    b.add_xaxis(xaxis_data=x)
    b.add_yaxis(series_name="",
                # xaxis_index=1,
                # yaxis_index=1,
                y_axis=y,
                label_opts=opts.LabelOpts(is_show=False))
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
            splitarea_opts=opts.SplitAreaOpts(is_show=True, areastyle_opts=opts.AreaStyleOpts(opacity=1)),
            axislabel_opts=opts.LabelOpts(is_show=False),
        ),
        legend_opts=opts.LegendOpts(is_show=True),
        )
    return b

def ind_bar(x, y, name="", grid_idx=1):
    b = Bar(init_opts=INIT_OPTS)
    b.add_xaxis(xaxis_data=x)
    b.add_yaxis(series_name=name,
                y_axis=y,
                # xaxis_index=grid_idx,
                # yaxis_index=grid_idx,
                label_opts=opts.LabelOpts(is_show=False))
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
            splitarea_opts=opts.SplitAreaOpts(is_show=True, areastyle_opts=opts.AreaStyleOpts(opacity=1)),
            axislabel_opts=opts.LabelOpts(is_show=False),
        ),
        legend_opts=opts.LegendOpts(is_show=True),
    )
    return b


def kline_chart(x, y, name="", index=1):
    k = Kline(init_opts=opts.InitOpts(width="1980px", height="1080px"))
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
    k.set_global_opts(
        legend_opts=opts.LegendOpts(
            is_show=False,
            pos_bottom=10,
            pos_left="center"),
        title_opts=opts.TitleOpts(title=name, pos_left="0"),
        yaxis_opts=opts.AxisOpts(
            is_scale=True,
            splitline_opts=opts.SplitLineOpts(is_show=True),
            splitarea_opts=opts.SplitAreaOpts(
                is_show=True, areastyle_opts=opts.AreaStyleOpts(opacity=1)
            ),
        ),
        tooltip_opts=opts.TooltipOpts(
            trigger="axis", axis_pointer_type="cross",
            background_color="rgba(245, 245, 245, 0.8)",
            border_width=1,
            border_color="#ccc",
            textstyle_opts=opts.TextStyleOpts(color="#000") ),
        visualmap_opts=opts.VisualMapOpts(
            is_show=False,
            dimension=2,
            series_index=5,
            is_piecewise=False,
            pieces=[
                {"value" : 1, "color" : "#00da3c"},
                {"value" : -1, "color" : "#ec0000"},
            ],
        ),
        axispointer_opts=opts.AxisPointerOpts(
            is_show=True,
            link=[{"xAxisIndex" : "all"}],
            label=opts.LabelOpts(background_color="#777"),
        ),
        brush_opts=opts.BrushOpts(
            x_axis_index="all",
            brush_link="all",
            out_of_brush={"colorAlpha" : 0.1},
            brush_type="lineX",
        ),
    )
    return k


def setzoom(chart, x_idx, y_idx=[]):
    if not y_idx:
        y_idx.extend(x_idx)

    chart.set_global_opts(datazoom_opts=[
        opts.DataZoomOpts(
            xaxis_index=x_idx,
            is_show=False,
            type_="inside",
            range_start=98,
            range_end=100
        ),
        opts.DataZoomOpts(
            xaxis_index=y_idx,
            is_show=True,
            type_="slider",
            pos_top="90%",
            range_start=98,
            range_end=100
        ),
    ])

def grid(dates, ohlc, inds: Dict[str, Tuple[str, List]]= {}):
    '''
    `inds`: Every indicator should specify its plot type. Eg. ("bar", [...])
    '''

    global INIT_OPTS
    INIT_OPTS = opts.InitOpts(width="1400px", height="800px")

    g = Grid(init_opts=INIT_OPTS)
    k_chart = kline_chart(dates, ohlc)
    v_bar = volume_bar(dates, inds["volume"][1])

    iinds = inds.copy()
    del iinds["volume"]
    # NOTE: Zoom needs to be applied before adding charts to the grid (They are copied?)
    zoom_idx = list(range(2 + len(iinds)))
    setzoom(k_chart, x_idx=zoom_idx)

    # NOTE: The order is importat for correct application of global options (like zoom)
    g.add(k_chart, grid_opts=opts.GridOpts(height="49%"))
    g.add(v_bar, grid_opts=opts.GridOpts(height="9%", pos_top="70%"))

    for (name, (plot_type, vec)) in iinds.items():
        i_bar = plotsfn[plot_type](dates, vec, name, grid_idx=2)
        g.add(i_bar, grid_opts=opts.GridOpts(height="9%", pos_top="80%"))




    g.render()


plotsfn = {
    "bar": ind_bar
    # "line": ind_line
    }
