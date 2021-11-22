var EVENT_HANDLER_API = "${event_handler_api}"
var SCOREBOARD_API = "${scoreboard_api}"

function loadHighestScore(callback) {

	const request = new XMLHttpRequest();
	request.onreadystatechange = function() {
		if (this.readyState == 4 && this.status == 200) {
			var result = JSON.parse(this.responseText);
			var highestScoreResult = result.scoreboard.sort(function(a, b) {
				var res = 0
				if (a.score > b.score) res = 1;
				if (b.score > a.score) res = -1;
				return res * -1;
			});;
			callback(highestScoreResult[0].score);
		}
	};
	
	request.open('POST', SCOREBOARD_API, true);
	request.send(); 

}

function getScoreboardJson(callback) {

	const request = new XMLHttpRequest();
	request.onreadystatechange = function() {
		if (this.readyState == 4 && this.status == 200) {
			var result = JSON.parse(this.responseText);
			var playersScores = result.scoreboard.sort(function(a, b) {
				var res=0
				if (a.score > b.score) res = 1;
				if (b.score > a.score) res = -1;
				if (a.score == b.score){
					if (a.level > b.level) res = 1;
					if (b.level > a.level) res = -1;
					if (a.level == b.level){
						if (a.losses < b.losses) res = 1;
						if (b.losses > a.losses) res = -1;
					} 
				} 
				return res * -1;
			});;
			callback(playersScores);
		}
	};
	
	request.open('POST', SCOREBOARD_API, true);
	request.send(); 

}
