"""Table files read as time series (normet-py's own reading), the trajectory joins,
and the air-quality adapters the Data Studio lists and downloads stations with.

The EEA and OpenAQ adapters are normet-py's own Python (vendored): they answer the
station-level queries the R package's bulk fetchers do not, and they need no R.
"""

from .eea import (  # noqa: F401
    EEA_POLLUTANT_CODES,
    fetch_eea_data,
    fetch_eea_station,
    list_eea_stations,
)
from .openaq import (  # noqa: F401
    fetch_openaq_measurements,
    openaq_locations,
    openaq_sensors,
)
from .tables import (  # noqa: F401
    TABLE_SUFFIXES,
    clock_to_utc,
    find_dates,
    on_clock,
    parse_dates,
    read_table,
    read_time_series,
    utc_to_clock,
)
from .trajectory import join_trajectory_features  # noqa: F401
