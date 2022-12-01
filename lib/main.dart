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

class Step {
  String startPattern = "";
  String endPattern = "";
  String name = "";
  RegExp? nameRegexp;
  Duration duration = Duration.zero;
  Step({this.startPattern = "", this.endPattern = "", this.name = "", this.nameRegexp, this.duration = Duration.zero});
}

class Job {
  String name = "";
  String key = "";
  BuildStatus status = BuildStatus.undefined;
  Duration duration = Duration.zero;

  bool _stepsExpanded = false;
  List<Step> steps = [];
}

class Stage {
  String name = "";
  BuildStatus status = BuildStatus.undefined;

  bool _jobsExpanded = false;
  List<Job> jobs = [];
}

class Build {
  BuildStatus status = BuildStatus.undefined;
  String name = "";
  String plan = "";
  int number = 0;
  Duration buildDuration = Duration.zero;
  Duration averageBuildDuration = Duration.zero;
  String get shortName {
    var words = name.split("-");
    return words.length > 3 ? "${words[1]}-${words[2]}" : name;
  }

  bool _stagesExpanded = false;
  List<Stage> stages = [];

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

  format(Duration d) => d.toString().split('.').first.padLeft(8, "0");

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
      var buildNumber = planResult["number"];
      var buildDuration = Duration.zero;
      var averageBuildDuration = Duration(seconds: (planStatus["averageBuildTimeInSeconds"] as double).toInt());

      if (state != BuildStatus.inProgress) {
        state = planResult["buildState"] == 'Failed' ? BuildStatus.failure : BuildStatus.success;
        buildDuration = Duration(seconds: planResult["buildDurationInSeconds"]);
      } else {
        do {
          buildNumber++;
          buildResult = await get(Uri.parse('${_config.bambooUrl}/rest/api/latest/result/${build.plan}-$buildNumber'),
              headers: <String, String>{'authorization': _basicAuth, 'Accept': 'application/json'});
          if (buildResult.statusCode != HttpStatus.ok) {
            _setStatusText("Error fetching build plan. Error: ${buildResult.statusCode}");
            return;
          }
          planResult = json.decode(buildResult.body);
        } while (planResult["buildReason"] == "Specs configuration updated");
        buildDuration = Duration(milliseconds: planResult["progress"]["buildTime"]);
      }

      setState(() {
        build.status = state;
        build.name = planStatus["shortName"];
        build.number = buildNumber;
        build.buildDuration = buildDuration;
        build.averageBuildDuration = averageBuildDuration;
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

  List<Step> buildStepPatterns = [
    Step(
        startPattern: "Starting task 'Checkout Default Repository'",
        endPattern: "Finished task: 'Checkout Default Repository'",
        name: "Checkout"),
    Step(startPattern: "Starting task 'Build'", endPattern: "Finished task 'Build'", name: "Build"),
    Step(startPattern: "Starting task 'Build Update'", endPattern: "Finished task 'Build Update'", name: "Build Update"),
    Step(startPattern: "Starting task 'Public PDB'", endPattern: "Finished task 'Public PDB'", name: "Public PDB"),
  ];

  String get _basicAuth => 'Basic ${base64Encode(utf8.encode('${_config.bambooUser}:${_config.bambooPassword}'))}';

  Widget createMainPage() {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: ListView(
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
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                      width: 3,
                    ),
                    Text(plan.name),
                    SizedBox(
                      width: 3,
                    ),
                    Text("[${plan.number}]"),
                    SizedBox(
                      width: 3,
                    ),
                    SizedBox(
                      width: 10,
                    ),
                    plan.status != BuildStatus.inProgress
                        ? TextButton(onPressed: () => _triggerBuild(plan), child: const Text("Run"))
                        : SizedBox(width: 0),
                    plan.status != BuildStatus.inProgress
                        ? TextButton(onPressed: () => _triggerRerun(plan), child: const Text("Re-run"))
                        : TextButton(onPressed: () => _triggerStop(plan), child: const Text("Stop")),
                    TextButton(onPressed: () => _launchBuild(plan), child: const Text("Open"))
                  ],
                ),
                Row(
                  children: [
                    SizedBox(
                      width: 25,
                    ),
                    IconButton(
                        icon: Icon(plan._stagesExpanded ? Icons.expand_less : Icons.expand_more),
                        onPressed: () => _toggleStageDetails(plan)),
                    Text(_getBuildDuration(plan)),
                  ],
                ),
                if (plan._stagesExpanded)
                  for (var stage in plan.stages)
                    Column(
                      children: [
                        Row(
                          children: [
                            SizedBox(
                              width: 50,
                            ),
                            IconButton(
                                icon: Icon(stage._jobsExpanded ? Icons.expand_less : Icons.expand_more),
                                onPressed: () => _toggleJobDetails(stage)),
                            SizedBox(
                              width: 3,
                            ),
                            Text(stage.name),
                            SizedBox(
                              width: 3,
                            ),
                            SizedBox(
                              width: 3,
                            ),
                            Text(_getStageDuration(stage)),
                          ],
                        ),
                        if (stage._jobsExpanded)
                          for (var job in stage.jobs)
                            Row(
                              children: [
                                SizedBox(
                                  width: 75,
                                ),
                                IconButton(
                                    icon: Icon(job._stepsExpanded ? Icons.expand_less : Icons.expand_more),
                                    onPressed: () => _toggleStepsDetails(job)),
                                Icon(_getIcon(job.status), color: _getStatusColor(job.status)),
                                SizedBox(
                                  width: 3,
                                ),
                                Text(job.name),
                                SizedBox(
                                  width: 3,
                                ),
                                Text(job.duration.toString()),
                              ],
                            ),
                      ],
                    ),
                SizedBox(
                  height: 10,
                ),
              ],
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
      ),
      body: createMainPage(),
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

  String _getBuildDuration(Build plan) {
    if (plan.buildDuration == Duration.zero) return "";
    return "duration: ${format(plan.buildDuration)}   average: ${format(plan.averageBuildDuration)}";
  }

  void _toggleStageDetails(Build build) async {
    if (build.stages.isEmpty) {
      var buildResult = await get(
          Uri.parse('${_config.bambooUrl}/rest/api/latest/result/${build.plan}-${build.number}?expand=plan.stages.stage.plans'),
          headers: <String, String>{'authorization': _basicAuth, 'Accept': 'application/json'});
      if (buildResult.statusCode != HttpStatus.ok) {
        _setStatusText("Error fetching build plan. Error: ${buildResult.statusCode}");
        return;
      }
      build.stages.clear();
      var planResult = json.decode(buildResult.body);
      var stages = planResult["plan"]["stages"]["stage"] as List<dynamic>;
      for (var jsonStage in stages) {
        var stage = Stage();
        build.stages.add(stage);
        stage.name = jsonStage["name"];
        var plans = jsonStage["plans"]["plan"] as List;
        for (var jsonJob in plans) {
          var job = Job();
          stage.jobs.add(job);
          job.name = jsonJob["shortName"];
          job.key = jsonJob["key"];
          var jobResult = await get(Uri.parse('${_config.bambooUrl}/rest/api/latest/result/${job.key}-${build.number}'),
              headers: <String, String>{'authorization': _basicAuth, 'Accept': 'application/json'});
          if (buildResult.statusCode != HttpStatus.ok) {
            _setStatusText("Error fetching build plan. Error: ${buildResult.statusCode}");
            return;
          }

          var jobResultJson = json.decode(jobResult.body);
          job.status = planResult["buildState"] == 'Failed' ? BuildStatus.failure : BuildStatus.success;
          job.duration = Duration(seconds: jobResultJson["buildDurationInSeconds"]);
        }
        stage.jobs.sort((a, b) => -1 * a.duration.compareTo(b.duration));
      }
    }

    setState(() {
      build._stagesExpanded = !build._stagesExpanded;
    });
  }

  String _getStageDuration(Stage stage) {
    if (stage.jobs.isEmpty) return "";

    return stage.jobs[0].duration.toString().split('.').first.padLeft(8, "0");
  }

  _toggleJobDetails(Stage stage) {
    setState(() {
      stage._jobsExpanded = !stage._jobsExpanded;
    });
  }

  _toggleStepsDetails(Job job) {
    setState(() {
      job._stepsExpanded = !job._stepsExpanded;
    });
  }
}
