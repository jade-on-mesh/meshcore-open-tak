// AI sketch HD's codec for iPhone: built into ios/lib/libaeic_hd.a by CI
// (tool/build_aeic_hd_ios.sh). This file is always compiled so the pod has a
// source of its own; it defines nothing the app looks up, so without the
// library the app finds no aeic_hd_run and says AI sketch HD can't run here.
int aeic_hd_pod_marker = 0;
