/***
* Name: Hall with Adrenaline and Cortisol + Path Aversion
* Author: Mikołaj Szurlej; Maciej Kamiński (mod: stress->route feedback)
* Description: Phantom develops a soft, probabilistic aversion to path
*              segments where it experienced fear. Aversion biases route
*              choice via dynamic edge weights; it does NOT hard-block paths.
*              aversion_strength = 0.0 reproduces the original baseline model.
* Tags: ABM, proxemics, feedback, route choice
***/

model Hall_AC

global {

    string roads_file <- "Staszica_SHP_sciezki_01.shp";
	file shape_file_roads <- file(roads_file);

   	string obstacle_file <- "Staszica_SHP_krzaki_09.shp";
	file shape_file_obstacles <- file(obstacle_file);

    geometry shape <- envelope(shape_file_roads);
    graph road_network;
    float step <- 0.005 #mn;
    int number_of_flags <- 0;

	float hall_multiplier <- 4.0;

	float intimate   <-  0.45* hall_multiplier;
	float personal <-  1.2 * hall_multiplier;
	float social <-  3.6 * hall_multiplier;
	float public <- 10.0 * hall_multiplier;

	// >>> FEEDBACK: globalne parametry awersji <<<
	// Siła awersji: 0.0 = brak (model identyczny z oryginałem), wyższe = silniejsze unikanie.
	// To jest Twoja zmienna eksperymentalna (odpowiednik "beta" z koncepcji).
	float aversion_strength <- 5.0;
	// Ile "strachu" odkłada się na odcinku, gdy phantom przekroczy próg lęku w danym cyklu.
	float fear_deposit <- 1.0;
	// Tempo zanikania pamięci strachu na odcinku (na cykl). 1.0 = brak zanikania.
	float fear_decay <- 0.999;
	// Co ile cykli przeliczamy graf (przeliczanie co cykl jest kosztowne).
	int reweight_every <- 20;
	// <<< FEEDBACK

	// Boty chodzą po grafie bez wag strachu (nie znają uczuć phantoma). false = dawne zachowanie: boty na grafie ważonym.
	bool bots_plain_graph <- true;
	graph bot_network;
	// Pamięć strachu: false = wspólna na odcinku dla wszystkich phantomów, true = osobna dla każdego phantoma.
	// Przy jednym phantomie oba warianty dają to samo.
	bool individual_fear <- false;
	// goto w GAMA traktuje wagi grafu także jako koszt RUCHU: na odcinku o wadze 10 × długość agent idzie 10× wolniej.
	// Przy awersji phantom zwalniał więc na odcinkach, na których się bał, zostawał w pobliżu źródła strachu i odkładał
	// kolejny strach (sprzężenie zwrotne; część phantomów prawie stawała). true = ruch z prędkością liczoną po długości,
	// wagi strachu służą tylko do wyboru trasy (jak w porcie Pythona). false = dawne zachowanie.
	bool move_by_length <- true;
	map<road, float> length_weights;

	// >>> PROFILE WIEKU (gałąź feature/profile-wieku; wartości domyślne = model jak w v1.0-ufug) <<<
	// Z3a: prędkość phantoma i koniec przebiegu jako parametry (wcześniej 4 km/h i 10000 na sztywno)
	float phantom_speed_kmh <- 4.0;
	int end_cycle <- 10000;
	float bot_speed_kmh <- 4.0;
	float bot_speed_sd <- 0.3;         // m/s, gauss(0, 0.3) jak dotąd
	// Z3b, Z12: typy botów (udziały od wszystkich botów, suma <= 1; reszta to piesi jak dotąd)
	float bot_older_share <- 0.0;
	float bot_older_speed_factor <- 0.85;
	float bot_run_share <- 0.0;
	float bot_run_speed_kmh <- 10.0;
	float bot_run_speed_sd <- 0.5;     // m/s
	float bot_bike_share <- 0.0;
	float bot_bike_speed_kmh <- 16.0;
	float bot_bike_speed_sd <- 1.0;    // m/s
	bool bike_paths_only <- false;     // rowerzyści tylko na odcinkach z atrybutem bicycle = yes/designated
	graph bike_network;
	list<road> bike_roads <- [];
	// Z4, Z4b: stożek widzenia i strefy za plecami
	float fov_deg <- 360.0;            // 360 = okręgi jak dotąd
	float rear_factor <- 1.0;          // mnożnik promieni poza stożkiem (Yu i in. 2020: ok. 0,6)
	int rear_zones <- 4;               // ile stref od intymnej istnieje za plecami: 4 = wszystkie, 2 = intymna i osobista
	bool rear_masked <- true;          // za plecami też maskowanie przeszkodami
	// Z4c: kierunek spojrzenia (tylko przy fov_deg < 360)
	float turn_rate_dps <- 0.0;        // °/s, maks. szybkość obrotu spojrzenia; 0 = spojrzenie = kierunek ruchu
	float scan_amp_deg <- 0.0;         // °, amplituda rozglądania się; 0 = brak
	float scan_period_s <- 4.0;        // s, okres rozglądania się
	// Z4d: pamięć widzianych osób: niewidoczny bot zachowuje ostatnią strefę przez memory_s sekund; 0 = bez pamięci
	float memory_s <- 0.0;
	// Z5: ciemność z lamp
	bool dark_on <- false;
	string lamps_file <- "";           // SHP z punktami lamp; puste = brak lamp (przy dark_on: pełna ciemność)
	float lamp_radius <- 10.0;
	float dark_detect_m <- 5.0;
	// Z6: sezon
	string season <- "summer";         // "winter": przeszkody z leaf_cycle = deciduous znikają
	float bush_evergreen_share <- 1.0; // zimą: udział zostających przeszkód bez leaf_cycle
	// Z14: przestrzeń ścieżki i ruch bez przenikania (skill pedestrian, model "advanced" = siła społeczna)
	bool path_space <- false;          // false = ruch po osi ścieżki jak dotąd (goto)
	float path_width_m <- 2.5;         // szerokość ścieżki bez atrybutu width w SHP
	float sfm_shoulder_length <- 0.45; // m, średnica ciała (shoulder_length skilla)
	float sfm_minimal_distance <- 0.25;
	float sfm_A_ped <- 0.16;
	float sfm_B_ped <- 0.1;
	float sfm_relax <- 0.5;
	float sfm_gamma <- 0.35;
	float sfm_lambda <- 0.1;
	float sfm_k <- 200.0;
	float sfm_kappa <- 400.0;
	float ped_consideration_m <- 3.0;
	float sfm_proba_detour <- 0.5;
	float waypoint_tolerance <- 1.0;
	bool hard_core <- true;            // krok zbliżający na < sfm_shoulder_length: krok w bok o 30/60/90° albo stoi
	graph space_network;               // graf odcinków (bez wag) do build_intersection_areas
	// boty i phantomy dla twardego rdzenia. Uwaga: kod gatunku bot nie może odwoływać się do gatunku phantom (także
	// pośrednio przez funkcje globalne): GAMA zmienia wtedy kolejność wykonywania gatunków i wyniki domyślne.
	list<agent> walkers <- [];
	// <<< PROFILE WIEKU

	// Z14: twardy rdzeń po do walk. Krok start -> location, który zbliża ciało na mniej niż sfm_shoulder_length
	// do innego (i bliżej niż przed krokiem), jest obracany o 30°, 60°, 90° najpierw w stronę przeciwną do
	// blokującego, potem w drugą; pierwszy krok w wolnej przestrzeni bez naruszenia rdzenia wygrywa, inaczej powrót.
	agent core_block(agent a, point start, point q) {
		float sh <- sfm_shoulder_length;
		list<agent> near <- walkers where (each != a and (each.location distance_to start) <= sh + (start distance_to q) + 1e-9);
		loop o over: near {
			float dn <- q distance_to o.location;
			if (dn < sh and dn < (start distance_to o.location)) { return o; }
		}
		return nil;
	}
	point core_fix(agent a, point start, road r) {
		point q <- a.location;
		if (q = start) { return q; }
		agent blk <- core_block(a, start, q);
		if (blk = nil) { return q; }
		float vx <- q.x - start.x;
		float vy <- q.y - start.y;
		float cr <- vx * (blk.location.y - start.y) - vy * (blk.location.x - start.x);
		float fs <- (cr >= 0) ? -1.0 : 1.0;
		loop sgn over: [fs, 0.0 - fs] {
			loop deg over: [30.0, 60.0, 90.0] {
				float t <- deg * sgn;
				point c <- {start.x + vx * cos(t) - vy * sin(t), start.y + vx * sin(t) + vy * cos(t)};
				if ((r = nil or r.free_space covers c) and core_block(a, start, c) = nil) { return c; }
			}
		}
		return start;
	}

	reflex stop_after_steps {
        if (cycle >= end_cycle) {
           	ask phantom{
           		do die;
           	}
           	ask bot{
           		do die;
           	}
           	do pause;
        }
    }

	int phantom_nb <- 1;
	int bot_nb <- 80;

    init {
    	if (season = "winter") {
    		// Z6: zimą krzewy liściaste nie zasłaniają (atrybut leaf_cycle w SHP przeszkód, jak w OSM)
    		create obstacle from: shape_file_obstacles with: [leaf::string(read("leaf_cycle"))];
    		ask obstacle {
    			if (leaf = "deciduous") { do die; }
    			else if ((leaf = nil or leaf = "" or leaf = "nil") and !flip(bush_evergreen_share)) { do die; }
    		}
    	} else {
    		create from: shape_file_obstacles species: obstacle  ;
    	}
    	if (bike_paths_only) {
    		create road from: shape_file_roads with: [bike_tag::string(read("bicycle"))];
    	} else {
        	create road from: shape_file_roads ;
        }
        if (path_space) {
        	// Z14: atrybut width (m) z SHP, jeśli jest
        	ask road {
        		string ws <- string(shape get "width");
        		if (ws != nil and ws != "" and ws != "nil") { width_m <- float(ws); }
        	}
        }
        create bot number: bot_nb {
        	speed <- bot_speed_kmh #km/#h + gauss(0, bot_speed_sd);
			location <- any_location_in( one_of(road) );
			target <- location;
			shape <- triangle(5);
        }
        create phantom number: phantom_nb {
        	speed <- phantom_speed_kmh #km/#h ;
			location <- any_location_in(one_of(road));
			target <- location;
			shape <- triangle(10);
		}
		// Z3b, Z12: typy botów po utworzeniu agentów (przy udziałach 0 nic się nie losuje: generator jak dotąd)
		if (bot_older_share + bot_run_share + bot_bike_share > 0.0) {
			ask bot {
				float u <- rnd(1.0);
				if (u < bot_run_share) {
					kind <- "run";
					speed <- max([0.0, bot_run_speed_kmh #km/#h + gauss(0, bot_run_speed_sd)]);
				} else if (u < bot_run_share + bot_bike_share) {
					kind <- "bike";
					speed <- max([0.0, bot_bike_speed_kmh #km/#h + gauss(0, bot_bike_speed_sd)]);
				} else if (u < bot_run_share + bot_bike_share + bot_older_share) {
					kind <- "older";
					speed <- speed * bot_older_speed_factor;
				}
			}
			if (bike_paths_only and bot_bike_share > 0.0) {
				bike_roads <- road where (each.bike_tag = "yes" or each.bike_tag = "designated");
				if (!empty(bike_roads)) {
					bike_network <- as_edge_graph(bike_roads);
					ask bot where (each.kind = "bike") {
						location <- any_location_in(one_of(bike_roads));
						target <- location;
					}
				}
			}
		}
		// Z14: wolna przestrzeń odcinków (bufor o połowę szerokości), sąsiedztwo, parametry skilla pedestrian
		if (path_space) {
			ask road {
				float w <- (width_m > 0.0) ? width_m : path_width_m;
				do initialize distance: w / 2.0;
				free_space <- shape + (w / 2.0);   // zaokrąglone końce: bez szczelin na załamaniach (jak w Pythonie)
				half_width <- w / 2.0;
			}
			space_network <- as_edge_graph(road);
			ask road { do build_intersection_areas pedestrian_graph: space_network; }
			walkers <- list<agent>(bot) + list<agent>(phantom);
			list<point> placed <- [];
			ask bot {
				do setup_space(placed);
				placed << location;
			}
			ask phantom {
				do setup_space(placed);
				placed << location;
			}
		}
		// Z4c: losowa faza rozglądania się (losowanie tylko przy scan_amp_deg > 0)
		if (scan_amp_deg > 0.0) {
			ask phantom { scan_phase <- rnd(360.0); }
		}
		// Z5: lampy
		if (lamps_file != "") {
			create lamp from: file(lamps_file);
		}

		// >>> FEEDBACK: graf z wagami zależnymi od pamięci strachu <<<
		// weights: dla każdej krawędzi (road) waga = długość * (1 + aversion_strength * fear_memory).
		// Przy fear_memory = 0 wszędzie -> waga = długość -> identyczny routing jak w oryginale.
		bot_network <- as_edge_graph(road);
		length_weights <- road as_map (each::each.shape.perimeter);
		do rebuild_graph;
		// <<< FEEDBACK
    }

	// >>> FEEDBACK: przebudowa ważonego grafu <<<
	action rebuild_graph {
		map<road, float> weights <- road as_map (each:: (each.shape.perimeter * (1.0 + aversion_strength * each.fear_memory)));
		road_network <- as_edge_graph(road) with_weights weights;
		if (individual_fear) {
			ask phantom {
				map<road, float> w <- road as_map (each:: (each.shape.perimeter * (1.0 + aversion_strength * ((my_fear contains_key each) ? my_fear[each] : 0.0))));
				my_network <- as_edge_graph(road) with_weights w;
			}
		}
	}

	// Okresowa aktualizacja: zanikanie strachu na wszystkich odcinkach + przeliczenie grafu.
	reflex update_aversion when: (cycle mod reweight_every) = 0 {
		ask road {
			fear_memory <- fear_memory * fear_decay;
		}
		ask phantom {
			loop r over: my_fear.keys {
				my_fear[r] <- my_fear[r] * fear_decay;
			}
		}
		do rebuild_graph;
	}
	// <<< FEEDBACK

    reflex save_results when: cycle = end_cycle - 1 {
    ask phantom {
        save [
            myself.bot_nb,
            myself.phantom_nb,
            total_adrenaline,
            total_cortisol,
            total_vigilance
        ]
        rewrite: false
        to: "results/summary.csv"
        header: ["bot_nb", "phantom_nb", "total_adrenaline", "total_cortisol", "total_vigilance"];
    }
}

}
species obstacle {
	string leaf <- "";   // Z6: leaf_cycle (tylko przy season = "winter")
	aspect default {
		draw shape color: rgb(0,255,0) at: location ;
	}
}

species bot skills: [pedestrian] {
	point target;
	string kind <- "walk";   // Z3b, Z12: walk / older / run / bike

	// Z14: start w losowym miejscu przekroju ścieżki (do 20 prób bez nakładania), ciało = punkt, parametry SFM
	action setup_space(list<point> placed) {
		road r <- road closest_to self;
		float h <- max([0.0, r.half_width - sfm_shoulder_length / 2.0]);
		geometry zone <- (h > 0.0) ? (r.shape + h) : r.shape;
		loop times: 20 {
			location <- any_location_in(zone);
			if (empty(placed where ((each distance_to location) < sfm_shoulder_length))) { break; }
		}
		shape <- location;
		pedestrian_model <- "advanced";
		shoulder_length <- sfm_shoulder_length;
		minimal_distance <- sfm_minimal_distance;
		A_pedestrians_SFM <- sfm_A_ped;
		B_pedestrians_SFM <- sfm_B_ped;
		relaxion_SFM <- sfm_relax;
		gama_SFM <- sfm_gamma;
		lambda_SFM <- sfm_lambda;
		k_SFM <- sfm_k;
		kappa_SFM <- sfm_kappa;
		pedestrian_consideration_distance <- ped_consideration_m;
		proba_detour <- sfm_proba_detour;
		tolerance_waypoint <- waypoint_tolerance;
		avoid_other <- true;
		obstacle_species <- [];
	}

	reflex normal_move {
		bool on_bike_net <- (kind = "bike") and (bike_network != nil);
		if (path_space) {
			point start <- location;
			if (final_waypoint = nil) {
				target <- on_bike_net ? any_location_in(one_of(bike_roads)) : any_location_in(one_of(road));
				do compute_virtual_path pedestrian_graph: (on_bike_net ? bike_network : (bots_plain_graph ? bot_network : road_network)) target: target;
			}
			do walk;
			if (hard_core) {
				road r <- (current_waypoint != nil and roads_waypoints contains_key current_waypoint) ? road(roads_waypoints[current_waypoint]) : (road closest_to self);
				location <- world.core_fix(self, start, r);
			}
			if (location != start) { heading <- start towards location; }   // walk nie ustawia heading
		} else {
			if ((target distance_to location)<1) {
				target <- on_bike_net ? any_location_in(one_of(bike_roads)) : any_location_in(one_of(road));
			}
			else {
				if (on_bike_net) {
					do goto target: target on: bike_network;
				} else if (move_by_length) {
					do goto target: target on: (bots_plain_graph ? bot_network : road_network) move_weights: length_weights;
				} else {
					do goto target: target on: (bots_plain_graph ? bot_network : road_network);
				}
			}
		}
	}

	aspect default {
		if (path_space) { draw triangle(1.0) rotate: heading + 90 color: #brown; }
		else { draw shape rotate: heading + 90 color: #brown; }
	}
}

species fear {
	float transparency;
	aspect default {
    	draw circle(10) color: rgb(255, 0, 0, int(transparency));
	}
}

species phantom skills: [pedestrian] {

   float total_adrenaline <- 0.0;
    float total_cortisol   <- 0.0;
    float total_vigilance  <- 0.0;

   point target;
   // własna pamięć strachu i graf (tylko przy individual_fear = true)
   map<road, float> my_fear <- [];
   graph my_network;

   float vigilance <- 0.5;
   float adrenaline <- 0.5;
   float cortisol <- 0.5;

   float adrenaline_cooldown <- 0.99;
   float cortisol_cooldown <- 0.999;

   list<int> where_are_they <- [];
   list<int> where_were_they <- [];

   geometry public_perception_geometry  update: circle(public, location)  masked_by obstacle;
   geometry social_perception_geometry  update: circle(social, location)  masked_by obstacle;
   geometry personal_perception_geometry  update: circle(personal, location)  masked_by obstacle;
   geometry intimate_perception_geometry    update: circle(intimate, location)    masked_by obstacle;
   // Z4b: strefy za plecami (liczone tylko przy fov_deg < 360; promienie × rear_factor, rear_zones stref od intymnej)
   geometry rear_intimate_geometry update: (fov_deg < 360.0 and rear_zones >= 1) ? (rear_masked ? (circle(intimate * rear_factor, location) masked_by obstacle) : circle(intimate * rear_factor, location)) : nil;
   geometry rear_personal_geometry update: (fov_deg < 360.0 and rear_zones >= 2) ? (rear_masked ? (circle(personal * rear_factor, location) masked_by obstacle) : circle(personal * rear_factor, location)) : nil;
   geometry rear_social_geometry   update: (fov_deg < 360.0 and rear_zones >= 3) ? (rear_masked ? (circle(social * rear_factor, location) masked_by obstacle) : circle(social * rear_factor, location)) : nil;
   geometry rear_public_geometry   update: (fov_deg < 360.0 and rear_zones >= 4) ? (rear_masked ? (circle(public * rear_factor, location) masked_by obstacle) : circle(public * rear_factor, location)) : nil;

   // Z4c: spojrzenie obraca się ku kierunkowi ruchu najwyżej o turn_rate_dps × krok, plus rozglądanie się
   float gaze <- 0.0;
   float look <- 0.0;
   bool gaze_ready <- false;
   float scan_phase <- 0.0;
   reflex update_gaze when: fov_deg < 360.0 {
      if (!gaze_ready or turn_rate_dps <= 0.0) {
         gaze <- heading;
         gaze_ready <- true;
      } else {
         float d <- heading - gaze;
         d <- d - 360.0 * floor((d + 180.0) / 360.0);
         float mx <- turn_rate_dps * step;
         gaze <- gaze + max([0.0 - mx, min([mx, d])]);
      }
      look <- gaze;
      if (scan_amp_deg > 0.0) {
         look <- gaze + scan_amp_deg * sin(360.0 * time / scan_period_s + scan_phase);
      }
   }

   list<int> mem_level <- [];
   list<int> mem_cycle <- [];

   reflex update_psychophysiology {
      where_are_they <- bot collect distance_number(each.location);
      if (memory_s > 0.0) {
         if (length(mem_level) != length(where_are_they)) {
            mem_level <- list_with(length(where_are_they), 0);
            mem_cycle <- list_with(length(where_are_they), -1000000000);
         }
         float span <- memory_s / step;
         loop i from: 0 to: (length(where_are_they) - 1) {
            if (where_are_they[i] > 0) {
               mem_level[i] <- where_are_they[i];
               mem_cycle[i] <- cycle;
            } else if ((cycle - mem_cycle[i]) <= span) {
               where_are_they[i] <- mem_level[i];
            }
         }
      }

      cortisol <- cortisol * cortisol_cooldown;
      cortisol <- cortisol + 0.2*adrenaline / ((cortisol + 1.0)*(cortisol + 1.0));

      vigilance <- required_vigilance();

      adrenaline <- adrenaline * adrenaline_cooldown;
      adrenaline <- adrenaline + vigilance;

      where_were_they <- where_are_they;
      if (adrenaline > 11.5) {
    	if (empty(fear at_distance 8)) {
        	create fear {
           		location <- myself.location;
            	transparency <- int(min(255.0, 255.0 * myself.adrenaline / 20.0));
      		}
   		}

   		// >>> FEEDBACK: odłóż strach na NAJBLIŻSZYM odcinku ścieżki <<<
   		// To jest "ślad" — odcinek, na którym phantom się przestraszył,
   		// staje się mniej atrakcyjny przy przyszłym wyborze trasy.
   		road scared_road <- road closest_to self;
   		if (scared_road != nil) {
   			scared_road.fear_memory <- scared_road.fear_memory + fear_deposit;
   			if (individual_fear) {
   				my_fear[scared_road] <- ((my_fear contains_key scared_road) ? my_fear[scared_road] : 0.0) + fear_deposit;
   			}
   		}
   		// <<< FEEDBACK
   	}
   	total_adrenaline <- total_adrenaline + adrenaline;
        total_cortisol   <- total_cortisol   + cortisol;
        total_vigilance  <- total_vigilance  + vigilance;
}

   int distance_number(geometry loc) {
      // Z5: osoba poza kręgiem lampy niewidoczna dalej niż dark_detect_m
      if (dark_on and (location distance_to loc) > dark_detect_m) {
         lamp l <- lamp closest_to loc;
         if (l = nil or (l distance_to loc) > lamp_radius) { return 0; }
      }
      // Z4, Z4b: poza stożkiem widzenia (kąt od kierunku ruchu > fov_deg / 2) tylko strefy za plecami
      if (fov_deg < 360.0 and (location distance_to loc) > 0.0) {
         float off <- (self towards loc) - look;
         off <- abs(off - 360.0 * floor((off + 180.0) / 360.0));
         if (off > fov_deg / 2.0) {
            if (rear_intimate_geometry != nil and rear_intimate_geometry covers loc) { return 4; }
            if (rear_personal_geometry != nil and rear_personal_geometry covers loc) { return 3; }
            if (rear_social_geometry != nil and rear_social_geometry covers loc) { return 2; }
            if (rear_public_geometry != nil and rear_public_geometry covers loc) { return 1; }
            return 0;
         }
      }
      if (intimate_perception_geometry covers loc)     { return 4; }
      if (personal_perception_geometry covers loc)   { return 3; }
      if (social_perception_geometry covers loc)   { return 2; }
      if (public_perception_geometry covers loc)   { return 1; }
      return 0;
   }

   float required_vigilance {
      if (length(where_were_they) = 0) {
         return 0.0;
      }
      float total <- 0.0;
      loop i from: 0 to: (length(where_are_they) - 1) {
         if (where_were_they[i] < where_are_they[i]) {
            int diff <- where_are_they[i] - where_were_they[i];
            total <- total + (diff * diff - 0.99);
         }
      }
      return total;
   }

	// >>> FEEDBACK: routing po WAŻONYM grafie <<<
	// goto z parametrem on: road_network (ważony) -> phantom wybiera trasę
	// minimalizującą sumę wag, czyli unika odcinków o wysokim fear_memory.
	// Mechanika ruchu i losowania celu pozostaje bez zmian.
	// Z14: jak u botów
	action setup_space(list<point> placed) {
		road r <- road closest_to self;
		float h <- max([0.0, r.half_width - sfm_shoulder_length / 2.0]);
		geometry zone <- (h > 0.0) ? (r.shape + h) : r.shape;
		loop times: 20 {
			location <- any_location_in(zone);
			if (empty(placed where ((each distance_to location) < sfm_shoulder_length))) { break; }
		}
		shape <- location;
		pedestrian_model <- "advanced";
		shoulder_length <- sfm_shoulder_length;
		minimal_distance <- sfm_minimal_distance;
		A_pedestrians_SFM <- sfm_A_ped;
		B_pedestrians_SFM <- sfm_B_ped;
		relaxion_SFM <- sfm_relax;
		gama_SFM <- sfm_gamma;
		lambda_SFM <- sfm_lambda;
		k_SFM <- sfm_k;
		kappa_SFM <- sfm_kappa;
		pedestrian_consideration_distance <- ped_consideration_m;
		proba_detour <- sfm_proba_detour;
		tolerance_waypoint <- waypoint_tolerance;
		avoid_other <- true;
		obstacle_species <- [];
	}

	reflex normal_move {
		if (path_space) {
			// ten sam cel; trasa przeliczana po każdej przebudowie wag strachu (co reweight_every cykli)
			point start <- location;
			if (final_waypoint = nil) {
				target <- any_location_in(one_of(road));
				do compute_virtual_path pedestrian_graph: (individual_fear ? my_network : road_network) target: target;
			} else if ((cycle mod reweight_every) = 0) {
				do compute_virtual_path pedestrian_graph: (individual_fear ? my_network : road_network) target: target;
			}
			do walk;
			if (hard_core) {
				road r <- (current_waypoint != nil and roads_waypoints contains_key current_waypoint) ? road(roads_waypoints[current_waypoint]) : (road closest_to self);
				location <- world.core_fix(self, start, r);
			}
			if (location != start) { heading <- start towards location; }   // walk nie ustawia heading
		} else {
			if ((target distance_to location)<1) {
				target <- any_location_in(one_of(road));
			}
			else {
				if (move_by_length) {
					do goto target: target on: (individual_fear ? my_network : road_network) move_weights: length_weights;
				} else {
					do goto target: target on: (individual_fear ? my_network : road_network);
				}
			}
		}
	}
	// <<< FEEDBACK

	aspect hall {
    	draw public_perception_geometry color: blend(#brown, #blue, 0.3) ;
	}
	aspect hall2 {
    	draw social_perception_geometry color: blend(#brown, #blue, 0.8) ;
	}
	aspect default {
		if (path_space) { draw triangle(2.0) rotate: heading + 90 color: #blue; }
		else { draw shape rotate: heading + 90 color: #blue; }
	}
}

species road skills: [pedestrian_road] {
    rgb color <- rgb(0,0,0) ;
    string bike_tag <- "";   // Z12: atrybut bicycle (tylko przy bike_paths_only)
    float width_m <- 0.0;    // Z14: atrybut width z SHP (0 = brak, wtedy path_width_m)
    float half_width <- 0.0;

	// >>> FEEDBACK: pamięć strachu na odcinku <<<
	float fear_memory <- 0.0;
	// <<< FEEDBACK

    aspect default {
    	// >>> FEEDBACK: wizualizacja awersji — im więcej strachu, tym bardziej czerwony odcinek <<<
    	draw shape color: rgb(int(min(255.0, 40.0 + fear_memory * 30.0)), 0, 0) width: 2.0;
    	// <<< FEEDBACK
	}
}

// Z5: lampa (punkt z pliku lamps_file)
species lamp {
	aspect default {
		draw circle(lamp_radius) color: rgb(255, 230, 120, 60) border: false;
	}
}

experiment Hall  type: gui {
	parameter "liczba phantomów" var: phantom_nb;
	parameter "liczba botów" var: bot_nb;
	parameter "distance intimate" var: intimate;
	parameter "distance personal" var: personal;
	parameter "distance social" var: social;
	parameter "distance public" var: public;
	parameter "Obstacle file" var: obstacle_file;
	parameter "Road file" var: roads_file;
	// >>> FEEDBACK: parametry awersji dostępne w GUI <<<
	parameter "Siła awersji (0 = baseline)" var: aversion_strength;
	parameter "Depozyt strachu" var: fear_deposit;
	parameter "Zanikanie strachu" var: fear_decay;
	parameter "Boty na grafie bez wag strachu" var: bots_plain_graph;
	parameter "Osobna pamięć strachu phantomów" var: individual_fear;
	parameter "Prędkość po długości (wagi tylko do trasy)" var: move_by_length;
	// <<< FEEDBACK
	// >>> PROFILE WIEKU <<<
	parameter "Prędkość phantoma (km/h)" var: phantom_speed_kmh category: "Populacja";
	parameter "Średnia prędkość botów (km/h)" var: bot_speed_kmh category: "Populacja";
	parameter "Odch. std. prędkości botów (m/s)" var: bot_speed_sd category: "Populacja";
	parameter "Koniec (cykl)" var: end_cycle category: "Przebieg";
	parameter "Udział starszych pieszych" var: bot_older_share category: "Typy botów";
	parameter "Mnożnik prędkości starszych" var: bot_older_speed_factor category: "Typy botów";
	parameter "Udział biegaczy" var: bot_run_share category: "Typy botów";
	parameter "Prędkość biegaczy (km/h)" var: bot_run_speed_kmh category: "Typy botów";
	parameter "Odch. std. biegaczy (m/s)" var: bot_run_speed_sd category: "Typy botów";
	parameter "Udział rowerzystów" var: bot_bike_share category: "Typy botów";
	parameter "Prędkość rowerzystów (km/h)" var: bot_bike_speed_kmh category: "Typy botów";
	parameter "Odch. std. rowerzystów (m/s)" var: bot_bike_speed_sd category: "Typy botów";
	parameter "Rowerzyści tylko na drogach rowerowych" var: bike_paths_only category: "Typy botów";
	parameter "Kąt stożka widzenia (°)" var: fov_deg category: "Percepcja";
	parameter "Mnożnik stref za plecami" var: rear_factor category: "Percepcja";
	parameter "Strefy za plecami (od intymnej)" var: rear_zones category: "Percepcja";
	parameter "Za plecami maskowanie przeszkodami" var: rear_masked category: "Percepcja";
	parameter "Szybkość obrotu spojrzenia (°/s)" var: turn_rate_dps category: "Percepcja";
	parameter "Rozglądanie się: amplituda (°)" var: scan_amp_deg category: "Percepcja";
	parameter "Rozglądanie się: okres (s)" var: scan_period_s category: "Percepcja";
	parameter "Pamięć widzianych osób (s)" var: memory_s category: "Percepcja";
	parameter "Ciemność (widać tylko w kręgu lamp)" var: dark_on category: "Ciemność i sezon";
	parameter "Plik lamp (SHP, punkty)" var: lamps_file category: "Ciemność i sezon";
	parameter "Promień kręgu lampy (m)" var: lamp_radius category: "Ciemność i sezon";
	parameter "Wykrycie w ciemności (m)" var: dark_detect_m category: "Ciemność i sezon";
	parameter "Sezon" var: season among: ["summer", "winter"] category: "Ciemność i sezon";
	parameter "Zimą udział zasłaniających (bez leaf_cycle)" var: bush_evergreen_share category: "Ciemność i sezon";
	parameter "Przestrzeń ścieżki (siła społeczna 2D)" var: path_space category: "Przestrzeń ścieżki";
	parameter "Szerokość ścieżki bez atrybutu width (m)" var: path_width_m category: "Przestrzeń ścieżki";
	parameter "Średnica ciała (m)" var: sfm_shoulder_length category: "Przestrzeń ścieżki";
	parameter "Minimalny odstęp (m)" var: sfm_minimal_distance category: "Przestrzeń ścieżki";
	parameter "SFM: A pieszych" var: sfm_A_ped category: "Przestrzeń ścieżki";
	parameter "SFM: B pieszych" var: sfm_B_ped category: "Przestrzeń ścieżki";
	parameter "SFM: czas relaksacji (s)" var: sfm_relax category: "Przestrzeń ścieżki";
	parameter "SFM: gamma" var: sfm_gamma category: "Przestrzeń ścieżki";
	parameter "SFM: lambda (anizotropia)" var: sfm_lambda category: "Przestrzeń ścieżki";
	parameter "SFM: k (sprężystość ciała)" var: sfm_k category: "Przestrzeń ścieżki";
	parameter "SFM: kappa (tarcie)" var: sfm_kappa category: "Przestrzeń ścieżki";
	parameter "Zasięg uwzględniania pieszych (m)" var: ped_consideration_m category: "Przestrzeń ścieżki";
	parameter "Prawdopodobieństwo objazdu" var: sfm_proba_detour category: "Przestrzeń ścieżki";
	parameter "Tolerancja punktu trasy (m)" var: waypoint_tolerance category: "Przestrzeń ścieżki";
	parameter "Twardy rdzeń (bez przenikania)" var: hard_core category: "Przestrzeń ścieżki";
	// <<< PROFILE WIEKU

    output {
        display city_display autosave: cycle=end_cycle type:opengl {
   	        species road  refresh: true;   // >>> FEEDBACK: było false; true, by widzieć narastającą awersję
   	        species obstacle refresh: false;
   	        species phantom aspect: hall;
   	        species phantom aspect: hall2;
   	        species phantom aspect: default;
   	        species lamp;
   	        species bot;
   	        species fear;
   	    }
   	    display chart type:2d refresh:every(1#cycle) {
			chart "Data" memorize: false y_range:{-0.1,55} type: series {
				data "adrenaline" value: phantom[0].adrenaline color:#blue;
				data "kortyzol" value: phantom[0].cortisol color: #purple;
				data "vigilance" value: phantom[0].vigilance color: rgb(0,0,0);
				}
			}
    }
}
