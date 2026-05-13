#! /bin/bash
echo "Safely shutting down jenkins"
java -jar /var/jenkins_home/war/WEB-INF/jenkins-cli.jar -auth $SERVICE_ACCOUNT -s http://localhost:8080/ safe-shutdown || exit 1
STATUS=200
while [[ "$STATUS" == 200 ]]
do
    STATUS=$(curl --write-out %{http_code} --silent --output /dev/null http://localhost:8080/robots.txt)
    echo "The status code for jenkins is $STATUS.  Sleeping for 5 seconds"
    sleep 5s  
done
exit 0