# bambie

Minimal bamboo UI build with Flutter.

The goal of this app is to have a small utility for watching build status.

The configuration is defined in a configuration file which should be located in your documents folder.

C:\Users\Me\Documents\bambie.json:

```json
{
  "bambooUrl": "https://bamboo-sample-server.com",
  "buildPlans": [ "project-plan"1, "project-plan2" ],
  "bambooUser": "user.name",
  "bambooPassword": "password"
}
```

