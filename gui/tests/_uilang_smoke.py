"""The R GUI in Chinese, run by test_uilang.py in a process of its own.

Installing .uilang wraps Qt's text setters for the rest of the process, so it is kept
out of the test run's own process. It also exits as the app does, wrappers installed,
so a crash at shutdown shows as this process failing.
"""

import os

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtWidgets import QApplication  # noqa: E402

from normet_r_gui import uilang  # noqa: E402

app = QApplication([])
uilang.install(app)
assert uilang.language() == "zh", uilang.language()

import matplotlib  # noqa: E402

matplotlib.use("QtAgg")
from normet_r_gui.main_window import MainWindow  # noqa: E402

w = MainWindow()
w.show()
app.processEvents()

# The screen shows Chinese while the code reads back the English it set.
tabs = w.tabs
assert tabs.tabText(0) == "Data", tabs.tabText(0)
shown = uilang._orig["QTabBar.tabText"](tabs.tabBar(), 0)
assert shown == "数据", shown
assert w.train_button.text().strip().endswith("Train model"), w.train_button.text()
assert "训练模型" in uilang._orig["QAbstractButton.text"](w.train_button)

# The menus, R's own included.
titles = [a.text() for a in w.menuBar().actions()]
assert "&R" in titles and "&View" in titles, titles
view = next(a.menu() for a in w.menuBar().actions() if a.text() == "&View")
language = next(a.menu() for a in view.actions() if a.menu() and a.text() == "&Language")
assert [a.text() for a in language.actions()] == ["Follow System", "English", "中文"]

# The example loads, its figure drawn; the studios open in Chinese too.
w.load_example()
w.open_scm_studio()
w.open_data_studio()
w.open_transport_studio()
for _ in range(5):
    app.processEvents()

# Back to English and to Chinese again: every text written again from its English.
uilang.set_language("en")
assert uilang._orig["QTabBar.tabText"](tabs.tabBar(), 0) == "Data"
uilang.set_language("zh")
assert uilang._orig["QTabBar.tabText"](tabs.tabBar(), 0) == "数据"

print("uilang smoke OK")
w.close()
