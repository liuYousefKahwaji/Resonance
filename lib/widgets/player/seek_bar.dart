// widgets/player/seek_bar.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';

class SeekBar extends StatefulWidget {
  const SeekBar({super.key});

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double _sliderValue = 0.0;
  bool _isScrubbing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _listenToPlayer();
  }

  void _listenToPlayer() {
    final handler = Provider.of<PlayerHandler>(context, listen: false);

    handler.positionStream.listen((position) {
      if (!_isScrubbing && mounted) {
        setState(() {
          _position = position;
          if (_duration.inMilliseconds > 0) {
            _sliderValue = _position.inMilliseconds / _duration.inMilliseconds;
          }
        });
      }
    });

    handler.durationStream.listen((duration) {
      if (duration != null && mounted) {
        setState(() {
          _duration = duration;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final handler = Provider.of<PlayerHandler>(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(_formatDuration(_position), style: const TextStyle(fontSize: 12)),
        const SizedBox(width: 8),
        Flexible(
          flex: 2,
          child: StreamBuilder(
            stream: handler.positionStream,
            builder: (context, snapshot) {
              return SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  // Show value indicator on hover (desktop) and long press (mobile)
                  showValueIndicator: ShowValueIndicator.onDrag,
                  valueIndicatorTextStyle: const TextStyle(color: Colors.white, fontSize: 12),
                ),
                child: Slider(
                  value: _sliderValue.clamp(0.0, 1.0),
                  min: 0,
                  max: 1,
                  divisions: _duration.inSeconds > 0 ? _duration.inSeconds : null,
                  label: _duration.inMilliseconds > 0 ? _formatDuration(_duration * _sliderValue) : '0:00',
                  onChanged: (value) {
                    setState(() {
                      _isScrubbing = true;
                      _sliderValue = value;
                    });
                  },
                  onChangeEnd: (value) {
                    final newPosition = _duration * value;
                    handler.seek(newPosition);
                    setState(() {
                      _isScrubbing = false;
                    });
                  },
                ),
              );
            }
          ),
        ),

        const SizedBox(width: 8),
        Text(_formatDuration(_duration), style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
}
