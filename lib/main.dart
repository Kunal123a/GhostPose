// GhostPose main.dart — LATEST 2026-10-24: uploaded ghost image keeps its own aspect ratio (default Fit), portrait removed, mode row grid-GHOST-timer, iPhone zoom, smooth zoom.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

List<CameraDescription> _cameras = [];

/// iOS Camera yellow.
const _accent = Color(0xFFFFD60A);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
  try {
    _cameras = await availableCameras();
  } catch (_) {
    _cameras = [];
  }
  runApp(const GhostPoseApp());
}

class GhostPoseApp extends StatelessWidget {
  const GhostPoseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GhostPose',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        colorScheme: const ColorScheme.dark(
          primary: _accent,
          surface: Colors.black,
        ),
        scaffoldBackgroundColor: Colors.black,
        sliderTheme: const SliderThemeData(
          activeTrackColor: _accent,
          inactiveTrackColor: Colors.white24,
          thumbColor: Colors.white,
          trackHeight: 3,
          thumbShape: RoundSliderThumbShape(enabledThumbRadius: 9),
          overlayShape: RoundSliderOverlayShape(overlayRadius: 16),
        ),
      ),
      home: const CameraScreen(),
    );
  }
}

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  int _cameraIndex = 0;
  bool _ready = false;
  bool _initializing = false; // guards against overlapping camera inits
  String? _error;

  // Overlay (pose reference)
  File? _overlayFile;
  bool _pickingImage = false;
  double _opacity = 0.45;
  double _scale = 1.0;
  Offset _offset = Offset.zero;
  bool _mirrored = false;
  bool _locked = false;
  bool _overlayVisible = true;
  final bool _ghostMode = true; // GHOST is the only mode now
  bool _ghostPanelOpen = false; // panel opens only when the user taps GHOST
  BoxFit _fit = BoxFit.contain;

  // Camera options
  FlashMode _flash = FlashMode.off;
  double _zoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  Timer? _zoomTimer;
  double? _pendingZoom;
  double? _pinchZoomStart;
  bool _showGrid = false;
  // Aspect ratio: 0=FULL, 1=4:3, 2=9:16, 3=1:1 (portrait values:
  // a vertical phone shows 4:3 as a tall 3:4 frame).
  int _aspectIndex = 0;
  static const _aspectLabels = ['FULL', '4:3', '9:16', '1:1'];
  static const _aspectValues = <double?>[null, 3 / 4, 9 / 16, 1.0];
  bool _hdr = false;
  bool _showSettings = false;
  int _timerSeconds = 0; // 0 = off
  int? _countdown;

  // Captured photos (this session)
  final List<File> _captured = [];
  bool _capturing = false;

  // Gesture bookkeeping for moving / pinch-scaling the overlay
  Offset? _focalStart;
  Offset _offsetStart = Offset.zero;
  double _scaleStart = 1.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _zoomTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      controller.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera(cameraIndex: _cameraIndex);
    }
  }

  Future<void> _initCamera({int cameraIndex = 0}) async {
    if (_initializing) return;
    _initializing = true;
    try {
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        setState(() => _error =
            'Camera permission denied. Allow camera access in Settings to use GhostPose.');
        return;
      }
      if (_cameras.isEmpty) {
        try {
          _cameras = await availableCameras();
        } catch (_) {}
      }
      if (_cameras.isEmpty) {
        setState(() => _error = 'No camera found on this device.');
        return;
      }
      _cameraIndex = cameraIndex % _cameras.length;
      // Release the old camera FIRST and wait for it: opening the new
      // controller while the old one still owns the camera session is
      // what left the front camera black or stuck initialising.
      final old = _controller;
      _controller = null;
      await old?.dispose();
      await Future.delayed(const Duration(milliseconds: 150));
      if (!mounted) return;
      final controller = CameraController(
        _cameras[_cameraIndex],
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      _controller = controller;
      try {
        await controller.initialize();
      } catch (e) {
        await controller.dispose();
        if (_controller == controller) _controller = null;
        if (!mounted) return;
        setState(() => _error = 'Could not start the camera: $e');
        return;
      }
      try {
        _minZoom = await controller.getMinZoomLevel();
        _maxZoom = await controller.getMaxZoomLevel();
        _zoom = 1.0;
      } catch (_) {}
      // Front cameras often don't support flash modes — never let that
      // fail the whole camera start.
      try {
        await controller.setFlashMode(_flash);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _ready = true;
        _error = null;
      });
    } finally {
      _initializing = false;
    }
  }

  // ---------- Overlay ----------

  Future<void> _pickOverlay() async {
    if (_pickingImage) return;
    setState(() => _pickingImage = true);
    try {
      if (Platform.isAndroid) {
        await Permission.photos.request();
        await Permission.storage.request();
      }
      final picker = ImagePicker();
      final picked =
          await picker.pickImage(source: ImageSource.gallery, imageQuality: 100);
      if (picked == null) {
        setState(() => _pickingImage = false);
        return;
      }
      final file = File(picked.path);
      if (!mounted) return;
      setState(() {
        _overlayFile = file;
        _opacity = 0.45;
        _scale = 1.0;
        _offset = Offset.zero;
        _mirrored = false;
        _locked = false;
        _overlayVisible = true;
        _pickingImage = false;
      });
      _toast('Ghost set — tap GHOST anytime for its controls');
    } catch (e) {
      if (mounted) {
        setState(() => _pickingImage = false);
      }
      _toast('Could not load image: $e');
    }
  }

  void _removeOverlay() {
    setState(() {
      _overlayFile = null;
      _offset = Offset.zero;
      _scale = 1.0;
    });
  }

  void _resetOverlayTransform() {
    setState(() {
      _offset = Offset.zero;
      _scale = 1.0;
      _mirrored = false;
    });
  }

  // ---------- Capture ----------

  Future<void> _onShutter() async {
    if (_capturing) return;
    if (_timerSeconds > 0) {
      for (var i = _timerSeconds; i > 0; i--) {
        if (!mounted) return;
        setState(() => _countdown = i);
        await Future.delayed(const Duration(seconds: 1));
      }
      if (!mounted) return;
      setState(() => _countdown = null);
    }
    await _capture();
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _capturing) {
      return;
    }
    setState(() => _capturing = true);
    try {
      final shot = await controller.takePicture();
      final dir = await getApplicationDocumentsDirectory();
      final folder = Directory('${dir.path}/GhostPose');
      if (!await folder.exists()) await folder.create(recursive: true);
      final name = 'pose_${DateTime.now().millisecondsSinceEpoch}.jpg';
      var saved = await File(shot.path).copy('${folder.path}/$name');
      saved = await _processCapture(saved);

      bool inGallery = false;
      try {
        if (await Gal.hasAccess()) {
          await Gal.putImage(saved.path, album: 'GhostPose');
          inGallery = true;
        } else if (await Gal.requestAccess()) {
          await Gal.putImage(saved.path, album: 'GhostPose');
          inGallery = true;
        }
      } catch (_) {
        inGallery = false;
      }

      if (!mounted) return;
      setState(() => _captured.insert(0, saved));
      _toast(inGallery ? 'Saved to your gallery' : 'Saved in app');
    } catch (e) {
      _toast('Capture failed: $e');
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  /// Applies the chosen aspect-ratio crop and, when HDR is on, a
  /// computational-HDR enhancement (shadow lift + contrast + colour)
  /// to the captured photo. Falls back to the original on any error.
  Future<File> _processCapture(File file) async {
    final ratio = _aspectValues[_aspectIndex];
    if (ratio == null && !_hdr) return file;
    try {
      final bytes = await file.readAsBytes();
      var decoded = img.decodeImage(bytes);
      if (decoded == null) return file;
      decoded = img.bakeOrientation(decoded);
      if (ratio != null) {
        final w = decoded.width;
        final h = decoded.height;
        final current = w / h;
        int cw = w, ch = h;
        if (current > ratio) {
          cw = (h * ratio).round();
        } else if (current < ratio) {
          ch = (w / ratio).round();
        }
        if (cw != w || ch != h) {
          decoded = img.copyCrop(decoded,
              x: (w - cw) ~/ 2, y: (h - ch) ~/ 2, width: cw, height: ch);
        }
      }
      if (_hdr) {
        decoded = img.adjustColor(decoded,
            brightness: 1.05, contrast: 1.14, saturation: 1.13, gamma: 1.06);
      }
      await file.writeAsBytes(img.encodeJpg(decoded, quality: 96));
      return file;
    } catch (_) {
      return file;
    }
  }

  // ---------- Camera controls ----------

  Future<void> _flipCamera() async {
    if (_cameras.length < 2) return;
    setState(() => _ready = false);
    await _initCamera(cameraIndex: (_cameraIndex + 1) % _cameras.length);
  }

  /// Smooth zoom like other camera apps: the on-screen zoom level
  /// (and preset highlight) updates instantly on every call, but the
  /// camera hardware only receives the latest requested value, at
  /// most once every 40ms. Awaiting every single drag/pinch update
  /// used to queue hardware calls up faster than the camera could
  /// answer them — that queue was the lag.
  Future<void> _setZoom(double level) async {
    final next = level.clamp(_minZoom, _maxZoom);
    if (mounted) setState(() => _zoom = next);
    _pendingZoom = next;
    _scheduleZoomApply();
  }

  void _scheduleZoomApply() {
    if (_zoomTimer?.isActive ?? false) return;
    _zoomTimer = Timer(const Duration(milliseconds: 40), () async {
      final target = _pendingZoom;
      _pendingZoom = null;
      final controller = _controller;
      if (target != null &&
          controller != null &&
          controller.value.isInitialized) {
        try {
          await controller.setZoomLevel(target);
        } catch (_) {}
      }
      // A newer value arrived while the hardware was busy: apply it.
      if (_pendingZoom != null) _scheduleZoomApply();
    });
  }

  Future<void> _cycleFlash() async {
    final next = switch (_flash) {
      FlashMode.off => FlashMode.auto,
      FlashMode.auto => FlashMode.always,
      FlashMode.always => FlashMode.torch,
      _ => FlashMode.off,
    };
    _flash = next;
    try {
      await _controller?.setFlashMode(next);
    } catch (_) {}
    setState(() {});
  }

  void _cycleTimer() {
    setState(() {
      _timerSeconds = switch (_timerSeconds) {
        0 => 3,
        3 => 5,
        5 => 10,
        _ => 0,
      };
    });
    if (_timerSeconds > 0) _toast('Timer: ${_timerSeconds}s');
  }

  IconData get _flashIcon => switch (_flash) {
        FlashMode.auto => Icons.flash_auto_rounded,
        FlashMode.always => Icons.flash_on_rounded,
        FlashMode.torch => Icons.highlight_rounded,
        _ => Icons.flash_off_rounded,
      };

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(msg, style: const TextStyle(color: Colors.white)),
        backgroundColor: Colors.white12,
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ));
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 500),
            child: _withPinchZoom(_viewfinderLayer()),
          ),
          if (_pickingImage)
            const Positioned.fill(
              child: ColoredBox(
                color: Colors.black54,
                child: Center(
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        SizedBox(
                          width: 56,
                          height: 56,
                          child: CircularProgressIndicator(
                            valueColor:
                                AlwaysStoppedAnimation<Color>(_accent),
                            strokeWidth: 2.5,
                          ),
                        ),
                        Icon(
                          Icons.photo_library_rounded,
                          size: 24,
                          color: _accent,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (_ready && _countdown != null) _countdownLayer(),
          if (_ready) ...[
            _topControls(),
            _settingsBar(),
            _bottomControls(),
          ],
        ],
      ),
    );
  }

  Widget _viewfinderLayer() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography_outlined,
                  size: 54, color: Colors.white54),
              const SizedBox(height: 14),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 18),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999)),
                ),
                onPressed: () {
                  setState(() {
                    _error = null;
                    _ready = false;
                  });
                  _initCamera(cameraIndex: _cameraIndex);
                },
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }
    final controller = _controller;
    if (!_ready || controller == null || !controller.value.isInitialized) {
      return const _AppLoadingView(key: ValueKey('app_loading_view'));
    }

    final isFront = _cameras.isNotEmpty &&
        _cameraIndex < _cameras.length &&
        _cameras[_cameraIndex].lensDirection == CameraLensDirection.front;

    final frame = Stack(
      fit: StackFit.expand,
      children: [
        // Live camera filling the chosen frame.
        FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: controller.value.previewSize!.height,
            height: controller.value.previewSize!.width,
            child: isFront
                ? Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()..scale(-1.0, 1.0),
                    child: CameraPreview(controller),
                  )
                : CameraPreview(controller),
          ),
        ),

        // Ghost overlay from the gallery.
        if (_ghostMode && _overlayFile != null && _overlayVisible)
          Positioned.fill(
            child: GestureDetector(
              onScaleStart: _locked
                  ? null
                  : (d) {
                      _focalStart = d.localFocalPoint;
                      _offsetStart = _offset;
                      _scaleStart = _scale;
                    },
              onScaleUpdate: _locked
                  ? null
                  : (d) {
                      setState(() {
                        if (d.scale != 1.0) {
                          _scale = (_scaleStart * d.scale).clamp(0.3, 4.0);
                        }
                        if (_focalStart != null) {
                          _offset =
                              _offsetStart + (d.localFocalPoint - _focalStart!);
                        }
                      });
                    },
              onScaleEnd: (_) => _focalStart = null,
              child: Opacity(
                opacity: _opacity,
                child: Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.identity()
                    ..translate(_offset.dx, _offset.dy)
                    ..scale(
                      (_mirrored == isFront) ? -_scale : _scale,
                      _scale,
                    ),
                  child: Image.file(
                    _overlayFile!,
                    fit: _fit,
                    width: double.infinity,
                    height: double.infinity,
                  ),
                ),
              ),
            ),
          ),

        if (_showGrid)
          const Positioned.fill(
            child: CustomPaint(painter: _GridPainter()),
          ),
      ],
    );

    final ratio = _aspectValues[_aspectIndex];
    if (ratio == null) return frame;
    // Frame the shot centred on screen, like a real camera app: the
    // frame size is computed explicitly from the screen size, so
    // changing the ratio always visibly resizes the preview.
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        final maxH = constraints.maxHeight;
        double w = maxW;
        double h = w / ratio;
        if (h > maxH) {
          h = maxH;
          w = h * ratio;
        }
        return Center(
          child: Container(
            width: w,
            height: h,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white24, width: 0.5),
            ),
            child: ClipRect(child: frame),
          ),
        );
      },
    );
  }

  Widget _countdownLayer() {
    return Center(
      child: Text(
        '$_countdown',
        style: const TextStyle(
          fontSize: 120,
          fontWeight: FontWeight.w200,
          color: Colors.white,
          shadows: [Shadow(color: Colors.black45, blurRadius: 24)],
        ),
      ),
    );
  }

  /// Small frosted-glass circular button, iOS Camera style.
  Widget _glassButton({
    required IconData icon,
    required VoidCallback onTap,
    bool active = false,
    String? badge,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withOpacity(0.38),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Icon(icon, size: 20, color: active ? _accent : Colors.white),
            if (badge != null)
              Positioned(
                right: 5,
                bottom: 5,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                  decoration: BoxDecoration(
                    color: _accent,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(badge,
                      style: const TextStyle(
                          fontSize: 8,
                          fontWeight: FontWeight.w800,
                          color: Colors.black)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _topControls() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Row(
            children: [
              // Brand pill
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.38),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.camera_alt_rounded, size: 15, color: _accent),
                    SizedBox(width: 6),
                    Text('GhostPose',
                        style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.3,
                            color: Colors.white)),
                  ],
                ),
              ),
              // Down arrow at the top centre — tap it and the
              // Aspect Ratio + HDR options drop down (iOS Camera style).
              // The arrow rotates smoothly instead of swapping icons.
              Expanded(
                child: Center(
                  child: GestureDetector(
                    onTap: () => setState(() => _showSettings = !_showSettings),
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black.withOpacity(0.38),
                      ),
                      child: AnimatedRotation(
                        turns: _showSettings ? 0.5 : 0.0,
                        duration: const Duration(milliseconds: 280),
                        curve: Curves.easeOutCubic,
                        child: Icon(Icons.keyboard_arrow_down_rounded,
                            size: 22,
                            color: _showSettings ? _accent : Colors.white),
                      ),
                    ),
                  ),
                ),
              ),
              _glassButton(
                icon: _flashIcon,
                active: _flash != FlashMode.off,
                onTap: _cycleFlash,
              ),
              const SizedBox(width: 10),
              _glassButton(
                icon: _overlayVisible
                    ? Icons.layers_rounded
                    : Icons.layers_clear_rounded,
                active: _overlayFile != null && _overlayVisible,
                onTap: _overlayFile == null
                    ? _pickOverlay
                    : () => setState(() => _overlayVisible = !_overlayVisible),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// iOS-style expandable settings bar: aspect ratio + HDR.
  /// Closed by default — it slides down from the top only when the
  /// user taps the down arrow.
  Widget _settingsBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.only(top: 62),
          child: Center(
            child: AnimatedSlide(
              offset: _showSettings ? Offset.zero : const Offset(0, -0.4),
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              child: AnimatedOpacity(
                opacity: _showSettings ? 1 : 0,
                duration: const Duration(milliseconds: 220),
                child: IgnorePointer(
                  ignoring: !_showSettings,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: BackdropFilter(
                      filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 7),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.42),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (var i = 0; i < _aspectLabels.length; i++)
                              _chip(_aspectLabels[i], _aspectIndex == i, () {
                                setState(() => _aspectIndex = i);
                                _toast('Aspect ratio: ${_aspectLabels[i]}');
                              }),
                            Container(
                              width: 1,
                              height: 18,
                              margin: const EdgeInsets.symmetric(horizontal: 6),
                              color: Colors.white24,
                            ),
                            _chip('HDR', _hdr, () {
                              setState(() => _hdr = !_hdr);
                              _toast(_hdr ? 'HDR on' : 'HDR off');
                            }),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? _accent : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: selected ? Colors.black : Colors.white70,
          ),
        ),
      ),
    );
  }

  Widget _bottomControls() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black54, Colors.black87],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 28, 20, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedSize(
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.bottomCenter,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child:
                        (_ghostMode && _overlayFile != null && _ghostPanelOpen)
                            ? KeyedSubtree(
                                key: const ValueKey('ghostPanel'),
                                child: _ghostPanel())
                            : (_ghostMode && _overlayFile == null)
                                ? KeyedSubtree(
                                    key: const ValueKey('ghostCta'),
                                    child: _ghostCta())
                                : const SizedBox(
                                    key: ValueKey('ghostEmpty'),
                                    width: double.infinity,
                                    height: 0),
                  ),
                ),
                const SizedBox(height: 14),
                _zoomControls(),
                const SizedBox(height: 12),
                _modeRow(),
                const SizedBox(height: 16),
                _shutterRow(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Slim hint — keeps the screen clean before a pose is picked.
  Widget _ghostCta() {
    return GestureDetector(
      onTap: _pickOverlay,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.45),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_pickingImage) ...[
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(_accent),
                ),
              ),
              const SizedBox(width: 8),
              const Text('Loading image...',
                  style: TextStyle(fontSize: 12.5, color: Colors.white70)),
            ] else ...[
              const Icon(Icons.layers_rounded, size: 15, color: _accent),
              const SizedBox(width: 7),
              const Text('Tap GHOST to add a pose photo',
                  style: TextStyle(fontSize: 12.5, color: Colors.white70)),
            ],
          ],
        ),
      ),
    );
  }

  /// Frosted glass panel with the ghost controls — appears only
  /// while a pose overlay is loaded.
  Widget _ghostPanel() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 10),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.10),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: Colors.white.withOpacity(0.14)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Text('GHOST',
                      style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.6,
                          color: Colors.white54)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Slider(
                      value: _opacity,
                      min: 0.05,
                      max: 1.0,
                      onChanged: (v) => setState(() => _opacity = v),
                    ),
                  ),
                  Text('${(_opacity * 100).round()}%',
                      style:
                          const TextStyle(fontSize: 12, color: Colors.white)),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _panelAction(
                      Icons.photo_library_rounded, 'Change', _pickOverlay),
                  _panelAction(Icons.flip_rounded, 'Mirror', () {
                    setState(() => _mirrored = !_mirrored);
                  }, active: _mirrored),
                  _panelAction(
                      _fit == BoxFit.cover
                          ? Icons.fit_screen_rounded
                          : Icons.fullscreen_rounded,
                      _fit == BoxFit.cover ? 'Fill' : 'Fit', () {
                    setState(() => _fit =
                        _fit == BoxFit.cover ? BoxFit.contain : BoxFit.cover);
                  }),
                  _panelAction(Icons.center_focus_strong_rounded, 'Reset',
                      _resetOverlayTransform),
                  _panelAction(
                      _locked ? Icons.lock_rounded : Icons.lock_open_rounded,
                      _locked ? 'Locked' : 'Move', () {
                    setState(() => _locked = !_locked);
                  }, active: _locked),
                  _panelAction(Icons.close_rounded, 'Remove', _removeOverlay),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _panelAction(IconData icon, String label, VoidCallback onTap,
      {bool active = false}) {
    final color = active ? _accent : Colors.white;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(height: 3),
            Text(label,
                style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w500,
                    color: color.withOpacity(0.85))),
          ],
        ),
      ),
    );
  }

  /// Apple-style mode strip: plain uppercase words, the active one
  /// in yellow. Every word here is a real control.
  /// Bottom mode row, iPhone-style: GHOST stays the primary mode in
  /// the centre; grid, timer and flip are icon symbols, and the
  /// redundant normal PHOTO mode is gone (GHOST already takes photos).
  /// iPhone-style zoom selector above the mode row: tap a preset
  /// (1x, 2x, max) to glide there, or drag horizontally across the
  /// pill to scrub the zoom like iPhone's zoom dial.
  List<double> get _zoomPresets {
    final presets = <double>[1.0, 2.0];
    if (_maxZoom >= 3) presets.add(_maxZoom);
    return presets.where((p) => p <= _maxZoom + 0.001).toList();
  }

  Widget _zoomControls() {
    return GestureDetector(
      onHorizontalDragUpdate: (d) {
        _setZoom(_zoom + d.delta.dx * 0.02);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.38),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final preset in _zoomPresets)
              GestureDetector(
                onTap: () => _setZoom(preset),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 13, vertical: 5),
                  decoration: BoxDecoration(
                    color: (_zoom - preset).abs() < 0.15
                        ? _accent
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    preset == preset.roundToDouble()
                        ? '${preset.toInt()}x'
                        : '${preset.toStringAsFixed(1)}x',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: (_zoom - preset).abs() < 0.15
                          ? Colors.black
                          : Colors.white70,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Pinch-to-zoom wrapper for the viewfinder. Pinch is the ghost's
  /// move/resize gesture while a ghost is loaded and unlocked, so
  /// pinch-zoom only takes over when the ghost is locked or no ghost
  /// is loaded yet — otherwise the pill's presets and drag do it.
  Widget _withPinchZoom(Widget child) {
    return GestureDetector(
      onScaleStart: (d) {
        if (_locked || _overlayFile == null) _pinchZoomStart = _zoom;
      },
      onScaleUpdate: (d) {
        final start = _pinchZoomStart;
        if (start != null && d.scale != 1.0) {
          final next = start * d.scale;
          if ((next - _zoom).abs() >= 0.05) {
            _setZoom(next);
          }
        }
      },
      onScaleEnd: (_) => _pinchZoomStart = null,
      child: child,
    );
  }

  /// Bottom mode row: grid on the left, GHOST in the centre, timer
  /// on the right. The flip button is NOT here — the shutter row
  /// already has one (bottom-right), so this row had a duplicate.
  Widget _modeRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _modeIcon(
          Icons.grid_3x3_rounded,
          active: _showGrid,
          onTap: () => setState(() => _showGrid = !_showGrid),
        ),
        GestureDetector(
          onTap: () {
            if (_overlayFile == null) {
              _pickOverlay();
            } else {
              setState(() => _ghostPanelOpen = !_ghostPanelOpen);
            }
          },
          behavior: HitTestBehavior.opaque,
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 22, vertical: 4),
            child: Text(
              'GHOST',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
                color: _accent,
              ),
            ),
          ),
        ),
        _modeIcon(
          Icons.timer_outlined,
          active: _timerSeconds > 0,
          badge: _timerSeconds > 0 ? '${_timerSeconds}s' : null,
          onTap: _cycleTimer,
        ),
      ],
    );
  }

  /// Small iPhone-style symbol button for the mode row.
  Widget _modeIcon(IconData icon,
      {bool active = false, String? badge, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: active ? _accent : Colors.white),
            if (badge != null) ...[
              const SizedBox(width: 3),
              Text(badge,
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: _accent)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _shutterRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Last captured photo (tap to view) — iOS style rounded thumb.
        GestureDetector(
          onTap: _captured.isEmpty ? _pickOverlay : _openCaptured,
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white38, width: 1.2),
              color: Colors.white10,
              image: _captured.isNotEmpty
                  ? DecorationImage(
                      image: FileImage(_captured.first), fit: BoxFit.cover)
                  : _overlayFile != null
                      ? DecorationImage(
                          image: FileImage(_overlayFile!), fit: BoxFit.cover)
                      : null,
            ),
            child: (_captured.isEmpty && _overlayFile == null)
                ? const Icon(Icons.photo_library_outlined,
                    size: 22, color: Colors.white70)
                : null,
          ),
        ),

        // Shutter — white ring, white core, exactly like iOS.
        GestureDetector(
          onTap: _onShutter,
          child: Container(
            width: 74,
            height: 74,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 4.5),
            ),
            child: Padding(
              padding: const EdgeInsets.all(4.5),
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _capturing ? Colors.white38 : Colors.white,
                ),
              ),
            ),
          ),
        ),

        // Flip camera — frosted circle.
        _glassButton(
          icon: Icons.cameraswitch_rounded,
          onTap: _flipCamera,
        ),
      ],
    );
  }

  void _openCaptured() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CapturedScreen(
          photos: List.of(_captured),
          onUseAsOverlay: (f) {
            Navigator.of(context).pop();
            setState(() {
              _overlayFile = f;
              _offset = Offset.zero;
              _scale = 1.0;
              _overlayVisible = true;
            });
          },
          onDelete: (f) => setState(() => _captured.remove(f)),
        ),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  const _GridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.4)
      ..strokeWidth = 0.7;
    for (var i = 1; i < 3; i++) {
      final dx = size.width * i / 3;
      final dy = size.height * i / 3;
      canvas.drawLine(Offset(dx, 0), Offset(dx, size.height), paint);
      canvas.drawLine(Offset(0, dy), Offset(size.width, dy), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Full-screen viewer for photos taken in this session.
class CapturedScreen extends StatefulWidget {
  const CapturedScreen({
    super.key,
    required this.photos,
    required this.onUseAsOverlay,
    required this.onDelete,
  });

  final List<File> photos;
  final ValueChanged<File> onUseAsOverlay;
  final ValueChanged<File> onDelete;

  @override
  State<CapturedScreen> createState() => _CapturedScreenState();
}

class _CapturedScreenState extends State<CapturedScreen> {
  late List<File> _photos;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _photos = widget.photos;
  }

  @override
  Widget build(BuildContext context) {
    if (_photos.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: const Text('Your shots', style: TextStyle(fontSize: 16)),
        ),
        body: const Center(
            child: Text('No photos left',
                style: TextStyle(color: Colors.white54))),
      );
    }
    final file = _photos[math.min(_index, _photos.length - 1)];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text('${_index + 1} of ${_photos.length}',
            style: const TextStyle(fontSize: 15, color: Colors.white70)),
        actions: [
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: () async {
              widget.onDelete(file);
              try {
                await file.delete();
              } catch (_) {}
              setState(() {
                _photos.remove(file);
                if (_index >= _photos.length) {
                  _index = math.max(0, _photos.length - 1);
                }
              });
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView.builder(
              itemCount: _photos.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (_, i) => InteractiveViewer(
                child: Image.file(_photos[i], fit: BoxFit.contain),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999)),
                ),
                icon: const Icon(Icons.layers_rounded, size: 19),
                label: const Text('Use as next ghost pose',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                onPressed: () => widget.onUseAsOverlay(file),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Simple loading icon shown when opening GhostPose & starting the camera.
class _AppLoadingView extends StatelessWidget {
  const _AppLoadingView({super.key});

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Colors.black,
      child: Center(
        child: SizedBox(
          width: 56,
          height: 56,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 56,
                height: 56,
                child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(_accent),
                  strokeWidth: 2.5,
                ),
              ),
              Icon(
                Icons.camera_alt_rounded,
                size: 24,
                color: _accent,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
