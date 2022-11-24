// ignore_for_file: prefer_const_constructors, prefer_final_fields

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:convert';
import 'package:http/http.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:url_launcher/url_launcher_string.dart';

enum BuildStatus { inProgress, failure, success, undefined }

void main() {
  runApp(const MyApp());
}

class Build {
  BuildStatus status = BuildStatus.undefined;
  String name = "";
  String plan = "";
  int number = 0;
  String get shortName {
    var words = name.split("-");
    return words.length > 3 ? "${words[1]}-${words[2]}" : name;
  }

  Build(this.plan);
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bambie - bamboo UI',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const MyHomePage(title: 'Bamboo builds'),
    );
  }
}

class Config {
  Future<File> _settingsFile() async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/bambie.json');
  }

  Future<String> _readSettings() async {
    try {
      final file = await _settingsFile();
      var content = await file.readAsString();
      var json = jsonDecode(content);
      bambooBuildPlans = List<String>.from(json["buildPlans"] as List);
      bambooUrl = json["bambooUrl"];
      bambooPassword = json["bambooPassword"];
      bambooUser = json["bambooUser"];
      return "";
    } catch (e) {
      return e.toString();
    }
  }

  var bambooUrl = "https://bamboo.com";
  var bambooPassword = "";
  var bambooUser = "firstname.lastname";

  List<String> bambooBuildPlans = ["project-plan1", "project-plan2", "project-plan2"];
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> with SingleTickerProviderStateMixin {
  String _statusText = "";
  List<Build> _builds = [];
  late Timer _timer;
  late AnimationController _animationController;
  Config _config = Config();

  Color _getStatusColor(BuildStatus state) {
    switch (state) {
      case BuildStatus.success:
        return Colors.green;
      case BuildStatus.failure:
        return Colors.red;
      case BuildStatus.inProgress:
      case BuildStatus.undefined:
        return Colors.grey;
    }
  }

  @override
  void didUpdateWidget(MyHomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _animationController.duration = Duration(microseconds: 500);
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  IconData _getIcon(BuildStatus state) {
    switch (state) {
      case BuildStatus.success:
        return Icons.check;
      case BuildStatus.failure:
        return Icons.error;
      case BuildStatus.inProgress:
        return Icons.hourglass_empty;
      case BuildStatus.undefined:
        return Icons.rectangle;
    }
  }

  void _fetchStatus(Build build) async {
    try {
      var response = await get(Uri.parse('${_config.bambooUrl}/rest/api/latest/plan/${build.plan}'),
          headers: <String, String>{'authorization': _basicAuth, 'Accept': 'application/json'});
      if (response.statusCode != HttpStatus.ok) {
        _setStatusText("Error fetching build plan. Error: ${response.statusCode}");
        return;
      }
      var planStatus = json.decode(response.body);
      var state = planStatus["isBuilding"] ? BuildStatus.inProgress : BuildStatus.failure;
      var buildResult = await get(Uri.parse('${_config.bambooUrl}/rest/api/latest/result/${build.plan}/latest'),
          headers: <String, String>{'authorization': _basicAuth, 'Accept': 'application/json'});
      if (buildResult.statusCode != HttpStatus.ok) {
        _setStatusText("Error fetching build plan. Error: ${buildResult.statusCode}");
        return;
      }
      var planResult = json.decode(buildResult.body);
      var buildNumber = planResult["number"] + 1;

      if (state != BuildStatus.inProgress) {
        state = planResult["buildState"] == 'Failed' ? BuildStatus.failure : BuildStatus.success;
        buildNumber = planResult["number"];
      }

      setState(() {
        build.status = state;
        build.name = planStatus["shortName"];
        build.number = buildNumber;
      });
    } catch (e) {
      _setStatusText("Error fetching status for build ${build.shortName}. Error: ${e.toString()}");
    }
  }

  intitBuilds() {
    var plans = _config.bambooBuildPlans;
    _builds = plans.map((e) => Build(e)).toList();
  }

  @override
  void initState() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initAsync();
    });
    _animationController = AnimationController(vsync: this, duration: Duration(seconds: 2))..repeat(reverse: true);
    _timer = Timer.periodic(const Duration(seconds: 10), (timer) {
      _fetchAll();
    });
    super.initState();
  }

  void _initAsync() async {
    var error = await _config._readSettings();
    if (error.isNotEmpty) {
      _setStatusText(error);
    }
    intitBuilds();
    for (var element in _builds) {
      _fetchStatus(element);
    }
  }

  _setStatusText(String text) {
    setState(() {
      _statusText = text;
    });
  }

  void _triggerBuild(Build build) async {
    try {
      var response = await post(Uri.parse('${_config.bambooUrl}/rest/api/latest/queue/${build.plan}'),
          headers: <String, String>{'authorization': _basicAuth, 'Accept': 'application/json'});
      if (response.statusCode != 200) {
        _setStatusText("Failed to trigger new build ${build.shortName}. Error: ${response.statusCode}");
      }
      _fetchStatus(build);
    } catch (e) {
      _setStatusText("Error triggering build ${build.shortName}. Error: ${e.toString()}");
    }
  }

  void _triggerRerun(Build build) async {
    try {
      var response = await put(Uri.parse('${_config.bambooUrl}/rest/api/latest/queue/${build.plan}-${build.number}'),
          headers: <String, String>{'authorization': _basicAuth, 'Accept': 'application/json'});
      if (response.statusCode != 200) {
        _setStatusText("Failed to rerun build ${build.shortName}. Error: ${response.statusCode}");
      }
      _fetchStatus(build);
    } catch (e) {
      _setStatusText("Failed to rerun build ${build.shortName}. Error: ${e.toString()}");
    }
  }

  void _triggerStop(Build build) async {
    try {
      var response = await delete(Uri.parse('${_config.bambooUrl}/rest/api/latest/queue/${build.plan}-${build.number}'),
          headers: <String, String>{'authorization': _basicAuth, 'Accept': 'application/json'});
      if (response.statusCode != 200) {
        _setStatusText("Failed to stop build ${build.shortName}. Error: ${response.statusCode}");
      }
    } catch (e) {
      _setStatusText("Failed to stop build ${build.shortName}. Error: ${e.toString()}");
    }
  }

  void _fetchAll() async {
    for (var element in _builds) {
      _fetchStatus(element);
    }
  }

  _launchBuild(Build build) async {
    var url = '${_config.bambooUrl}/browse/${build.plan}';
    if (await canLaunchUrlString(url)) {
      await launchUrlString(url);
    } else {
      _setStatusText('Could not launch $url');
    }
  }

  String get _basicAuth => 'Basic ${base64Encode(utf8.encode('${_config.bambooUser}:${_config.bambooPassword}'))}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
      ),
      body: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              height: 10,
            ),
            Text(
              _config.bambooUrl,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            SizedBox(
              height: 10,
            ),
            for (var plan in _builds)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  plan.status != BuildStatus.inProgress
                      ? Icon(_getIcon(plan.status), color: _getStatusColor(plan.status))
                      : AnimatedRotation(
                          turns: 100,
                          duration: Duration(minutes: 120),
                          child: Icon(Icons.autorenew, color: _getStatusColor(plan.status)),
                        ),
                  SizedBox(
                    width: 10,
                  ),
                  Text(plan.name),
                  Text("[${plan.number}]"),
                  plan.status != BuildStatus.inProgress
                      ? TextButton(onPressed: () => _triggerBuild(plan), child: const Text("Run"))
                      : SizedBox(width: 0),
                  plan.status != BuildStatus.inProgress
                      ? TextButton(onPressed: () => _triggerRerun(plan), child: const Text("Re-run"))
                      : TextButton(onPressed: () => _triggerStop(plan), child: const Text("Stop")),
                  TextButton(onPressed: () => _launchBuild(plan), child: const Text("Open"))
                ],
              ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _fetchAll,
        tooltip: 'FetchStatus',
        child: const Icon(Icons.refresh),
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_statusText),
            GestureDetector(
              onTap: () => _setStatusText(""),
              child: _statusText.isNotEmpty
                  ? Icon(
                      Icons.close,
                      color: Colors.red,
                      size: 25,
                    )
                  : SizedBox(
                      width: 0,
                      height: 0,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
