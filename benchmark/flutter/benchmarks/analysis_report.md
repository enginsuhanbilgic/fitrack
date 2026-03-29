# Benchmark Analysis Report
# Issue 1 

## Performance Summary

| Model | Mean Latency | P50 (Median) | P95 Latency | Avg FPS | Detection Rate |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **ML Kit Pose** | **19.38 ms** | **14.08 ms** | **37.43 ms** | **22.14** | 92.55% |
| **ML Kit Full** | 23.72 ms | 17.10 ms | 43.34 ms | 18.27 | 99.75% |
| **MoveNet Lightning** | 33.05 ms | 26.33 ms | 65.36 ms | 21.41 | **100.00%** |
| **YOLO26n-Pose** | 126.64 ms | 111.63 ms | 239.41 ms | 6.86 | 96.83% |
| **MediaPipe Lite** | ~200 ms | - | - | 5.0 | - |
| **MediaPipe Full** | ~250 ms | - | - | 4.0 | - |

## Key Findings

1. **Efficiency Champion:** **ML Kit Pose** demonstrates the best overall performance with the lowest latency (19.38 ms mean) and highest frame rate (22.14 FPS). It is the most suitable for real-time mobile applications.
2. **Accuracy Leader:** **MoveNet Lightning** achieved a perfect 100% detection rate during the session, followed closely by ML Kit Full (99.75%).
3. **Hardware Constraints:** **YOLO26n-Pose** performed significantly worse in this environment (running on an arm64 emulator), with a mean latency of 126.64 ms and only 6.86 FPS. This suggests it may require more optimization or better hardware acceleration to be viable for real-time use.
4. **Latency Stability:** ML Kit variants show the most stable performance (lowest P95/P50 ratio), indicating fewer spikes in processing time.
5. **MediaPipe Performance Bottleneck:** Raw MediaPipe TFLite implementations (Lite and Full) showed significantly lower performance in the Flutter environment, with frame rates dropping to **4-5 FPS**. This suggests that running these models directly via TFLite without specialized platform-native optimizations is not optimal for real-time Flutter applications, likely due to overhead in data conversion and lack of native acceleration hooks compared to the ML Kit counterparts.

## Conclusion

For general use, **ML Kit Pose** offers the best balance of speed and detection reliability. If absolute detection coverage is required over raw speed, **MoveNet Lightning** is the preferred alternative. Raw MediaPipe implementations are currently not recommended for production Flutter apps due to severe performance degradation.


