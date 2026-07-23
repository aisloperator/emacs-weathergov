;;; weathergov.el --- Fetch and use weather.gov forecast data  -*- lexical-binding: t; -*-

;; Created by AI Sloperator (https://www.aisloperator.com/) using
;; Claude Code, on July 15th, 2026.

;; Keywords: comm, data
;; Version: 0.1
;; Package-Requires: ((emacs "26.1"))

;; This file is not part of GNU Emacs.

;;; Commentary:

;; `weathergov' fetches forecast data from the U.S. National Weather
;; Service (weather.gov) "DWML" XML API, and parses it into a plain
;; Emacs Lisp s-expression structure (the same structure produced by
;; `xml-parse-region'), for other Emacs Lisp code to consume.
;;
;; Customize `weathergov-data-url' to point at the forecast location
;; you want.  The default value is a "MapClick" URL for a fixed
;; latitude and longitude; you can get a URL like this for your own
;; location from https://forecast.weather.gov/, by finding the
;; corresponding MapClick link and making sure it has
;; "FcstType=dwml" so that XML is returned instead of HTML.
;;
;; The core function is `weathergov-fetch-data', which returns the
;; parsed data as an s-expression, and is intentionally general
;; purpose rather than tailored to any one command.  Commands that
;; do something specific with the data (summarize it, show a
;; forecast, etc.) are built on top of it.
;;
;; Command:
;;
;;   M-x weathergov-insert
;;     Fetch the data and insert a compact one-line ASCII summary of
;;     current conditions at point, for logging into notes.
;;
;; `weathergov-show' and `weathergov-raw' are plain (non-interactive)
;; functions rather than commands, to keep the M-x namespace
;; uncluttered; call them from Lisp:
;;
;;   (weathergov-raw)
;;     Fetch the data and pretty-print the raw parsed s-expression
;;     into a buffer, `*weathergov-raw*'.
;;
;;   (weathergov-show)
;;     Fetch the data and show a human-readable report of current
;;     conditions and the text forecast, in a buffer,
;;     `*weathergov-show*'.

;;; Code:

(require 'url)
(require 'xml)
(require 'pp)
(require 'view)
(require 'seq)

(defgroup weathergov nil
  "Fetch and use weather data from weather.gov."
  :group 'comm
  :prefix "weathergov-")

(defface weathergov-title-face
  '((t :inherit bold :height 1.2))
  "Face for the location title line in `weathergov-show' reports."
  :group 'weathergov)

(defface weathergov-heading-face
  '((t :inherit bold :underline t))
  "Face for section headings in `weathergov-show' reports."
  :group 'weathergov)

(defface weathergov-period-name-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for forecast period names (\"Tonight\", \"Thursday\", ...)
in `weathergov-show' reports."
  :group 'weathergov)

(defface weathergov-precip-face
  '((t :inherit font-lock-constant-face))
  "Face for probability-of-precipitation figures in `weathergov-show'
reports."
  :group 'weathergov)

(defface weathergov-hazard-face
  '((t :inherit error))
  "Face for hazard/alert headlines in `weathergov-show' reports."
  :group 'weathergov)

(defface weathergov-label-face
  '((t :inherit shadow))
  "Face for field labels (e.g. \"Wind:\") in `weathergov-show' reports."
  :group 'weathergov)

(defcustom weathergov-data-url
  "https://forecast.weather.gov/MapClick.php?lat=42.3652&lon=-71.105&unit=0&lg=english&FcstType=dwml"
  "URL of the weather.gov DWML XML data to fetch.

This is normally a \"MapClick\" URL for a specific latitude and
longitude, with \"FcstType=dwml\" in the query string so that XML
data is returned (rather than an HTML page).  You can get such a URL
for your own location from the forecast map at
URL `https://forecast.weather.gov/'."
  :type 'string
  :group 'weathergov)

(defun weathergov--parse-response-buffer (buffer)
  "Parse the HTTP response BUFFER as XML, returning an s-expression.
BUFFER is expected to be a buffer as created by
`url-retrieve-synchronously', containing the HTTP response headers
followed by the XML body.  Signal an error if the HTTP status
indicates failure."
  (with-current-buffer buffer
    (unless (boundp 'url-http-end-of-headers)
      (error "weathergov: response does not look like an HTTP response"))
    (when (and (boundp 'url-http-response-status)
               url-http-response-status
               (>= url-http-response-status 400))
      (error "weathergov: HTTP request failed with status %s"
             url-http-response-status))
    (goto-char (or url-http-end-of-headers (point-min)))
    (xml-parse-region (point) (point-max))))

(defun weathergov-fetch-data (&optional url)
  "Fetch weather data from URL, and return it as an s-expression.

URL defaults to `weathergov-data-url'.

The data is fetched and parsed as XML via `xml-parse-region', giving
a list of elements of the form (TAG ATTRIBUTES . CHILDREN).  This
function deliberately returns that general-purpose structure as-is,
rather than extracting or reshaping anything for a particular use,
so that other functions can pick out of it whatever they need."
  (let* ((url (or url weathergov-data-url))
         (buffer (url-retrieve-synchronously url t t 30)))
    (unless buffer
      (error "weathergov: failed to retrieve %s" url))
    (unwind-protect
        (weathergov--parse-response-buffer buffer)
      (kill-buffer buffer))))

;; The following functions know how to navigate the particular shape
;; of DWML data, for use by report-building commands such as
;; `weathergov-show'.  They are not part of `weathergov-fetch-data',
;; which stays general-purpose.

(defconst weathergov--compass-points
  ["N" "NNE" "NE" "ENE" "E" "ESE" "SE" "SSE"
   "S" "SSW" "SW" "WSW" "W" "WNW" "NW" "NNW"]
  "16-point compass direction names, indexed by 22.5-degree sector.")

(defun weathergov--attr (node attr)
  "Return the value of attribute ATTR (a symbol) on NODE, or nil.
The value is whitespace-trimmed: unlike element text, `xml.el' does
not trim attribute values, and weather.gov attributes such as
`weather-summary' and hazard `headline' are sometimes padded with a
leading space (meant for concatenation after a coverage word)."
  (let ((v (cdr (assq attr (xml-node-attributes node)))))
    (if (stringp v) (string-trim v) v)))

(defun weathergov--text (node)
  "Return the trimmed text content of NODE, or nil if empty.
This is for leaf elements such as <value>70</value>, which weather.gov
also sometimes leaves empty, as in <value xsi:nil=\"true\"></value>."
  (let ((s (string-trim
            (mapconcat (lambda (c) (if (stringp c) c "")) (xml-node-children node) ""))))
    (unless (string-empty-p s) s)))

(defun weathergov--child-text (node tag)
  "Return the text content of NODE's first child element named TAG."
  (let ((child (car (xml-get-children node tag))))
    (and child (weathergov--text child))))

(defun weathergov--values (node)
  "Return the list of <value> texts within NODE, in order.
An empty/nil-flagged value becomes nil in the list, as does
weather.gov's own \"NA\" (not available) placeholder text, so that
callers don't mistake it for a real reading (e.g. a calm/unmeasured
wind speed rendered as literal text \"NA\")."
  (mapcar (lambda (n)
            (let ((v (weathergov--text n)))
              (unless (equal v "NA") v)))
          (xml-get-children node 'value)))

(defun weathergov--unit-suffix (units)
  "Return a short display suffix for a weather.gov UNITS string, or nil."
  (when units
    (pcase units
      ("Fahrenheit" "°F")
      ("Celsius" "°C")
      ("knots" " kt")
      ("percent" "%")
      ("inches of mercury" " inHg")
      (_ (concat " " units)))))

(defun weathergov--format-value (node &optional default-suffix)
  "Return NODE's first <value>, formatted with its units attribute.
If NODE has no `units' attribute, DEFAULT-SUFFIX is appended instead
\(and may be nil for no suffix at all)."
  (let ((v (car (weathergov--values node))))
    (and v (concat v (or (weathergov--unit-suffix (weathergov--attr node 'units))
                          default-suffix
                          "")))))

(defun weathergov--compass-direction (degrees-string)
  "Return a 16-point compass direction name for DEGREES-STRING."
  (when degrees-string
    (let* ((deg (mod (round (string-to-number degrees-string)) 360))
           (idx (mod (round (/ deg 22.5)) 16)))
      (aref weathergov--compass-points idx))))

(defun weathergov--format-timestamp (iso)
  "Return a friendlier rendering of ISO-8601 timestamp string ISO.
Falls back to returning ISO unchanged if it isn't in the expected
weather.gov \"yyyy-mm-ddThh:mm:ss+zz:zz\" form."
  (if (and iso (string-match "\\`\\([0-9-]+\\)T\\([0-9]\\{2\\}:[0-9]\\{2\\}\\)" iso))
      (concat (match-string 1 iso) " " (match-string 2 iso))
    iso))

(defun weathergov--data-section (dwml type)
  "Return the <data> child of DWML whose `type' attribute is TYPE."
  (seq-find (lambda (node) (equal (weathergov--attr node 'type) type))
            (xml-get-children dwml 'data)))

(defun weathergov--location-description (data-section)
  "Return a human-readable location name for DATA-SECTION, or nil."
  (let ((loc (car (xml-get-children data-section 'location))))
    (when loc
      (or (weathergov--child-text loc 'description)
          (weathergov--child-text loc 'area-description)
          (weathergov--child-text loc 'city)))))

(defun weathergov--time-layout-periods (data-section layout-key)
  "Return the ordered period names for LAYOUT-KEY in DATA-SECTION.
Each element of the returned list is the `period-name' attribute of
one <start-valid-time>, e.g. \"Tonight\" or \"Thursday\"."
  (catch 'weathergov--found
    (dolist (tl (xml-get-children data-section 'time-layout))
      (when (equal (weathergov--child-text tl 'layout-key) layout-key)
        (throw 'weathergov--found
               (mapcar (lambda (n) (weathergov--attr n 'period-name))
                       (xml-get-children tl 'start-valid-time)))))))

(defun weathergov--find-parameter (parameters tag &optional type)
  "Return the first child of PARAMETERS named TAG.
If TYPE is non-nil, only consider children whose `type' attribute
equals TYPE."
  (seq-find (lambda (n) (or (not type) (equal (weathergov--attr n 'type) type)))
            (xml-get-children parameters tag)))

(defun weathergov--weather-summaries (weather-node)
  "Return the ordered list of weather-summary strings in WEATHER-NODE."
  (mapcar (lambda (n) (weathergov--attr n 'weather-summary))
          (xml-get-children weather-node 'weather-conditions)))

(defun weathergov--hazard-headlines (parameters)
  "Return the list of hazard headline strings in PARAMETERS, if any."
  (let ((hazards (car (xml-get-children parameters 'hazards))))
    (when hazards
      (seq-mapcat (lambda (hc)
                    (mapcar (lambda (h) (weathergov--attr h 'headline))
                            (xml-get-children hc 'hazard)))
                  (xml-get-children hazards 'hazard-conditions)))))

(defun weathergov--insert-heading (text)
  "Insert TEXT as a report section heading at point."
  (insert (propertize text 'face 'weathergov-heading-face) "\n"))

(defun weathergov--insert-label-value (label value)
  "Insert a \"LABEL VALUE\" report line at point, or nothing if VALUE is nil."
  (when value
    (insert (propertize (format "%-12s" label) 'face 'weathergov-label-face)
            value "\n")))

(defun weathergov--insert-current-conditions (current)
  "Insert a \"Current Conditions\" report section for CURRENT at point.
CURRENT is a <data type=\"current observations\"> element."
  (let* ((parameters (car (xml-get-children current 'parameters)))
         (time-layout (car (xml-get-children current 'time-layout)))
         (observed-at (and time-layout
                            (weathergov--child-text time-layout 'start-valid-time)))
         (weather (weathergov--find-parameter parameters 'weather))
         (summary (and weather (seq-find #'identity (weathergov--weather-summaries weather))))
         (apparent (weathergov--find-parameter parameters 'temperature "apparent"))
         (dewpoint (weathergov--find-parameter parameters 'temperature "dew point"))
         (humidity (weathergov--find-parameter parameters 'humidity "relative"))
         (wind-dir (weathergov--find-parameter parameters 'direction "wind"))
         (wind-speed (weathergov--find-parameter parameters 'wind-speed "sustained"))
         (wind-gust (weathergov--find-parameter parameters 'wind-speed "gust"))
         (pressure (weathergov--find-parameter parameters 'pressure "barometer")))
    (weathergov--insert-heading
     (if observed-at
         (format "Current Conditions (as of %s)" (weathergov--format-timestamp observed-at))
       "Current Conditions"))
    (when summary (insert summary "\n"))
    (when apparent
      (weathergov--insert-label-value "Feels like:" (weathergov--format-value apparent)))
    (when dewpoint
      (weathergov--insert-label-value "Dew point:" (weathergov--format-value dewpoint)))
    (when humidity
      (weathergov--insert-label-value "Humidity:" (weathergov--format-value humidity "%")))
    (let* ((dir (and wind-dir (weathergov--compass-direction (car (weathergov--values wind-dir)))))
           (spd (and wind-speed (weathergov--format-value wind-speed)))
           (gust (and wind-gust (weathergov--format-value wind-gust))))
      (when spd
        (weathergov--insert-label-value
         "Wind:"
         (concat (and dir (concat dir " ")) spd (and gust (format ", gusting to %s" gust))))))
    (when pressure
      (weathergov--insert-label-value "Pressure:" (weathergov--format-value pressure)))))

(defun weathergov--insert-hazards (forecast)
  "Insert any hazard/alert headlines for FORECAST at point.
FORECAST is a <data type=\"forecast\"> element."
  (let* ((parameters (car (xml-get-children forecast 'parameters)))
         (headlines (delq nil (weathergov--hazard-headlines parameters))))
    (when headlines
      (dolist (headline headlines)
        (insert (propertize (concat "⚠ " headline) 'face 'weathergov-hazard-face) "\n"))
      (insert "\n"))))

(defun weathergov--insert-forecast (forecast)
  "Insert a \"Forecast\" report section for FORECAST at point.
FORECAST is a <data type=\"forecast\"> element."
  (weathergov--insert-heading "Forecast")
  (let* ((parameters (car (xml-get-children forecast 'parameters)))
         (worded (car (xml-get-children parameters 'wordedForecast))))
    (if (not worded)
        (insert "(No text forecast available.)\n")
      (let* ((layout-key (weathergov--attr worded 'time-layout))
             (periods (weathergov--time-layout-periods forecast layout-key))
             (texts (mapcar #'weathergov--text (xml-get-children worded 'text)))
             (weather (weathergov--find-parameter parameters 'weather))
             (summaries (and weather
                             (equal (weathergov--attr weather 'time-layout) layout-key)
                             (weathergov--weather-summaries weather)))
             (pop-node (weathergov--find-parameter parameters 'probability-of-precipitation))
             (pops (and pop-node
                        (equal (weathergov--attr pop-node 'time-layout) layout-key)
                        (weathergov--values pop-node)))
             (pop-suffix (or (and pop-node (weathergov--unit-suffix (weathergov--attr pop-node 'units)))
                              "%")))
        (if (null periods)
            (insert "(No forecast periods found.)\n")
          (dotimes (i (length periods))
            (let ((period-name (or (nth i periods) (format "Period %d" (1+ i))))
                  (summary (nth i summaries))
                  (pop (nth i pops))
                  (text (or (nth i texts) "")))
              (insert (propertize period-name 'face 'weathergov-period-name-face))
              (when summary (insert "  " summary))
              (when pop
                (insert "  " (propertize (format "(%s%s chance of rain)" pop pop-suffix)
                                          'face 'weathergov-precip-face)))
              (insert "\n")
              (let ((text-start (point))
                    (fill-prefix "    "))
                (insert "    " text "\n")
                (fill-region text-start (point)))
              (insert "\n"))))))))

(defun weathergov--insert-report (data)
  "Insert a formatted, human-readable weather report for DATA at point.
DATA is as returned by `weathergov-fetch-data'."
  (let* ((dwml (car data))
         (forecast (weathergov--data-section dwml "forecast"))
         (current (weathergov--data-section dwml "current observations"))
         (head (car (xml-get-children dwml 'head)))
         (product (and head (car (xml-get-children head 'product))))
         (source (and head (car (xml-get-children head 'source))))
         (created (and product (weathergov--child-text product 'creation-date)))
         (center (and source (weathergov--child-text source 'production-center))))
    (insert (propertize (or (and forecast (weathergov--location-description forecast))
                             (and current (weathergov--location-description current))
                             "Weather Report")
                         'face 'weathergov-title-face)
            "\n")
    (when created
      (insert (propertize "Updated:" 'face 'weathergov-label-face)
              " " (weathergov--format-timestamp created)
              (if center (format "  (%s)" center) "")
              "\n"))
    (insert "\n")
    (when current
      (weathergov--insert-current-conditions current)
      (insert "\n"))
    (when forecast
      (weathergov--insert-hazards forecast)
      (weathergov--insert-forecast forecast))))

(defun weathergov-show (&optional url)
  "Fetch weather.gov data and show a human-readable report.

Calls `weathergov-fetch-data' and pops to a buffer named
\"*weathergov-show*\" showing a report of current conditions and the
text forecast, formatted with faces for readability.

URL defaults to `weathergov-data-url'.  This is a plain function, not
a command; call it from Lisp."
  (let ((data (weathergov-fetch-data url))
        (buffer (get-buffer-create "*weathergov-show*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (weathergov--insert-report data)
        (goto-char (point-min)))
      (view-mode 1))
    (pop-to-buffer buffer)))

(defvar weathergov--last-pressure-value nil
  "The most recently seen barometric pressure, as a number.
Used by `weathergov--pressure-trend' to report a rise/fall trend from
one call of `weathergov-insert' to the next within the
same Emacs session.  There is no trend history before the first
call, so nil here means \"unknown\".")

(defun weathergov--pressure-trend (current)
  "Compare CURRENT barometric pressure against the last-seen value.
Return \"up\", \"down\", \"steady\", or nil if there is no previous
value to compare against.  Also update the stored last-seen value to
CURRENT, as a side effect."
  (prog1
      (when weathergov--last-pressure-value
        (cond ((> current weathergov--last-pressure-value) "up")
              ((< current weathergov--last-pressure-value) "down")
              (t "steady")))
    (setq weathergov--last-pressure-value current)))

(defun weathergov--compact-unit-suffix (units)
  "Return a short, plain-ASCII display suffix for weather.gov UNITS, or nil."
  (when units
    (pcase units
      ("Fahrenheit" "F")
      ("Celsius" "C")
      ("knots" "kt")
      ("percent" "%")
      ("inches of mercury" "in")
      (_ units))))

(defun weathergov--format-value-compact (node &optional default-suffix)
  "Return NODE's first <value> glued tightly to its units, e.g. \"30.01in\".
If NODE has no `units' attribute, DEFAULT-SUFFIX is used instead (and
may be nil for no suffix at all)."
  (let ((v (car (weathergov--values node))))
    (and v (concat v (or (weathergov--compact-unit-suffix (weathergov--attr node 'units))
                          default-suffix
                          "")))))

(defun weathergov--find-temperature-untyped (parameters)
  "Return a <temperature> child of PARAMETERS that has no `type' attribute.
Such an element, when present, is the actual (non-apparent) reading,
as opposed to types like \"apparent\" or \"dew point\"."
  (seq-find (lambda (n) (not (weathergov--attr n 'type)))
            (xml-get-children parameters 'temperature)))

(defun weathergov--hyphenate (text)
  "Return TEXT downcased with runs of whitespace replaced by hyphens.
E.g. \"Air Quality Alert\" becomes \"air-quality-alert\".  Leading and
trailing whitespace is discarded rather than turned into a hyphen;
weather.gov's `weather-summary' values are sometimes padded with a
leading space, since they are meant to be concatenated after a
coverage word (e.g. \"Chance\" + \" Thunderstorm\") when one is
present."
  (downcase (replace-regexp-in-string "[ \t\n\r]+" "-" (string-trim text))))

(defun weathergov--dense-current-line (current forecast)
  "Return a compact, single-line ASCII summary of current conditions.
CURRENT is a <data type=\"current observations\"> element.  FORECAST,
if non-nil, is a <data type=\"forecast\"> element, used to add the
next forecast high and low."
  (let* ((cur-params (car (xml-get-children current 'parameters)))
         (actual (weathergov--find-temperature-untyped cur-params))
         (apparent (weathergov--find-parameter cur-params 'temperature "apparent"))
         (actual-str (and actual (weathergov--format-value-compact actual)))
         (apparent-str (and apparent (weathergov--format-value-compact apparent)))
         (main-str (or actual-str apparent-str))
         (chunks nil))
    (push "Weather.gov" chunks)
    (when main-str
      (push main-str chunks))
    (when (and actual-str apparent-str (not (equal actual-str apparent-str)))
      (push (concat "feels " apparent-str) chunks))
    (when forecast
      (let* ((f-params (car (xml-get-children forecast 'parameters)))
             (high (weathergov--find-parameter f-params 'temperature "maximum"))
             (low (weathergov--find-parameter f-params 'temperature "minimum"))
             (high-str (and high (weathergov--format-value-compact high)))
             (low-str (and low (weathergov--format-value-compact low))))
        (when high-str (push (concat "high " high-str) chunks))
        (when low-str (push (concat "low " low-str) chunks))))
    (let* ((humidity (weathergov--find-parameter cur-params 'humidity "relative"))
           (humidity-str (and humidity (weathergov--format-value-compact humidity "%"))))
      (when humidity-str
        (push (concat "humidity " humidity-str) chunks)))
    (let* ((pressure (weathergov--find-parameter cur-params 'pressure "barometer"))
           (pv (and pressure (car (weathergov--values pressure)))))
      (when pv
        (let ((trend (weathergov--pressure-trend (string-to-number pv))))
          (push (concat "pressure " (if trend (format "(%s)" trend) "")
                        (weathergov--format-value-compact pressure))
                chunks))))
    (let* ((wind-dir (weathergov--find-parameter cur-params 'direction "wind"))
           (wind-speed (weathergov--find-parameter cur-params 'wind-speed "sustained"))
           (speed-str (and wind-speed (weathergov--format-value-compact wind-speed))))
      (when speed-str
        (push (concat "wind "
                      (or (weathergov--compass-direction (car (weathergov--values wind-dir))) "")
                      speed-str)
              chunks)))
    (let* ((dewpoint (weathergov--find-parameter cur-params 'temperature "dew point"))
           (dewpoint-str (and dewpoint (weathergov--format-value-compact dewpoint))))
      (when dewpoint-str
        (push (concat "dewpoint " dewpoint-str) chunks)))
    (let* ((weather (weathergov--find-parameter cur-params 'weather))
           (summary (and weather (seq-find #'identity (weathergov--weather-summaries weather)))))
      (when summary
        (push (weathergov--hyphenate summary) chunks)))
    (when forecast
      (let* ((f-params (car (xml-get-children forecast 'parameters)))
             (headlines (delq nil (weathergov--hazard-headlines f-params))))
        (dolist (headline headlines)
          (push (weathergov--hyphenate headline) chunks))))
    (mapconcat #'identity (nreverse chunks) " ")))

;;;###autoload
(defun weathergov-insert (&optional url)
  "Fetch weather.gov data and insert a compact one-line summary at point.

The line is prefixed with \"Weather.gov\", followed by the current
temperature (and \"feels like\" temperature, if distinct), the next
forecast high and low, humidity, barometric pressure, wind, dew
point, general sky conditions, and any active hazard headlines, all
as compact plain ASCII text with no location name -- meant for
logging into notes.  For example:

    Weather.gov 79F feels 83F high 82F low 67F humidity 50% pressure
    (down)30.01in air-quality-alert

The pressure trend (\"(up)\", \"(down)\", or \"(steady)\") is relative
to the last time this command fetched data in the current Emacs
session; it is omitted the first time, since there is nothing yet to
compare against.

With a prefix argument, prompt for URL to fetch instead of using
`weathergov-data-url'."
  (interactive
   (list (when current-prefix-arg
           (read-string "Weather data URL: " weathergov-data-url))))
  (let* ((data (weathergov-fetch-data url))
         (dwml (car data))
         (current (weathergov--data-section dwml "current observations"))
         (forecast (weathergov--data-section dwml "forecast")))
    (unless current
      (error "weathergov: no current-observations data in response"))
    (insert (weathergov--dense-current-line current forecast))))

(defun weathergov-raw (&optional url)
  "Fetch weather.gov data and show the raw parsed s-expression.

Calls `weathergov-fetch-data' and pops to a buffer named
\"*weathergov-raw*\" showing the returned s-expression,
pretty-printed.

URL defaults to `weathergov-data-url'.  This is a plain function, not
a command; call it from Lisp."
  (let ((data (weathergov-fetch-data url))
        (buffer (get-buffer-create "*weathergov-raw*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (emacs-lisp-mode)
        (pp data buffer)
        (goto-char (point-min)))
      (view-mode 1))
    (pop-to-buffer buffer)))

(provide 'weathergov)

;;; weathergov.el ends here
