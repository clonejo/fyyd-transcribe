#!/bin/bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

if [ -f ./fyyd.cfg ]
	then
		source "./fyyd.cfg"
	else
		echo "no config found. please run setup.sh first."
		exit 0
fi


if [ -z $ATOKEN  ]
	then
		echo "Please get an accesstoken first. Visit https://fyyd.de/dev/app/ to create one."
		exit 0;
fi

export LC_NUMERIC="en_US.UTF-8"

trap ctrl_c INT
trap stop EXIT

function stop {
	rm -f $PIDFILE
}

function ctrl_c() {
	
	echo "------------------------------"
	echo "STOPPING... sending notification to fyyd"
	echo "bye bye"
	echo "------------------------------"
	curl -H "Authorization: Bearer $ATOKEN" "https://api.fyyd.de/0.2/transcribe/error/$ID" -d "error=0"
	rm -f $PIDFILE
	exit 
}

pid() {
	if [ -f $PIDFILE ]
	then
	  PID=$(cat $PIDFILE)
	  ps -p $PID > /dev/null 2>&1
	  if [ $? -eq 0 ]
	  then
		echo "Process already running"
		exit 1
	  else
		## Process not found assume not running
		echo $$ > $PIDFILE
		if [ $? -ne 0 ]
		then
		  echo "Could not create PID file"
		  exit 1
		fi
	  fi
	else
	  echo $$ > $PIDFILE
	  if [ $? -ne 0 ]
	  then
		echo "Could not create PID file"
		exit 1
	  fi
	fi
}

pid

echo "Checking for updates"

./update.sh

echo "Starting engines! Let's transcribe some episodes"
cd whisper.cpp

while :
do

	#------------------------------------------------------------------------------------
	# get data for one episode to transcribe from fyyd.de
	#------------------------------------------------------------------------------------
	
	ID=""
	
	echo "getting data from fyyd"
	DATA=`echo $(curl -s -H "Authorization: Bearer $ATOKEN"  "https://api.fyyd.de/0.2/transcribe/next")`

	eval "$(echo $DATA |jq -r '.data | to_entries | .[] | .key + "=" + (.value | @sh)')"	

	# exit if nothing to do

	if [ -z $ID  ]
		then
			echo "nothing to transcribe. exit!"
			exit 0;
	fi
	
	#------------------------------------------------------------------------------------
	# download episode 
	#------------------------------------------------------------------------------------
	
	echo "starting download of episode $ID, \"$TITLE\", duration $DURATION seconds"

	curl -s -L "${URL}" > $TOKEN
	if [ $? -ne 0 ]
		then
			echo "error downloading"
			curl -H "Authorization: Bearer $ATOKEN" "https://api.fyyd.de/0.2/transcribe/error/$ID" -d "error=10"
			continue
		
	fi
	
	
	#------------------------------------------------------------------------------------
	# convert whatever was donwloaded to 16kHz WAV 
	#------------------------------------------------------------------------------------
	
	echo "converting to wav"

	ffmpeg -y -i $TOKEN -acodec pcm_s16le -ac 1 -ar 16000 $TOKEN.wav >/dev/null  2>/dev/null
	
	if [ $? -eq 1 ]
		then
			echo "error converting to wav"
			curl -H "Authorization: Bearer $ATOKEN" "https://api.fyyd.de/0.2/transcribe/error/$ID" -d "error=11"
			continue
	fi

	rm $TOKEN
	
	#------------------------------------------------------------------------------------
	# transcribe wav to vtt
	#------------------------------------------------------------------------------------

	if [ "$LANG" == "null" ]
		then
			$LANG = "auto"
	fi
	
	START=`date +%s`
	
	echo "starting whisper"
	nice -n 18 ./main -m models/ggml-$MODEL.bin -t $THREADS -l $LANG -ovtt $TOKEN.wav >/dev/null 2>/dev/null
	
	if [ $? -ne 0 ]
		then
			echo "error transcribing"
			curl -H "Authorization: Bearer $ATOKEN" "https://api.fyyd.de/0.2/transcribe/error/$ID" -d "error=12"
			continue
		
	fi
	
	END=`date +%s`
	TOOK=$(($END-$START))

	echo -n "Rate: "
	printf "%.2f" $(echo "$DURATION/$TOOK" | bc -l)
	echo "x"
	
		
	#------------------------------------------------------------------------------------
	# push transcript to fyyd
	#------------------------------------------------------------------------------------
	
	echo "sending transcript to fyyd"
	curl -H "Authorization: Bearer $ATOKEN" "https://api.fyyd.de/0.2/transcribe/set/$ID" --data-binary @$TOKEN.wav.vtt
	rm $TOKEN.wav
	rm $TOKEN.wav.vtt
	
	if [ -f ~/.fyyd-stop ]; then
		rm ~/.fyyd-stop
		echo "stopping hard"
		exit
	fi

	echo "--------------------------------------------------------------"
	sleep 2
done

rm $PIDFILE
