#!/bin/bash
#
# orahot.sh - performs a backup (hot) of the database one tablespace at a time - good old fashioned backup
#
#          this will not work with ASM systems and should be run on an instance level
#
#          We have decided that hot backups backups will go to /hot_backup
#
# Femi Adams - 27th April, 2023
#

. /home/oracle/scripts/functions.sh

if [ $# != 1 ]; then
  echo "Syntax Error. This code requires one parameter"
  exit 1
fi

YYMMDD=`date +'%Y%m%d%H%M'`
ORACLE_SID=$1
BU_LOCATION=/hot_backup
BU_FILES_DIR=${BU_LOCATION}/orahot_${ORACLE_SID}_${YYMMDD}
export BU_RECOVERY_FILES=${BU_FILES_DIR}/orahot_${ORACLE_SID}_recovery.sh

LOGFILE=/home/oracle/logs/orahot_${ORACLE_SID}_${YYMMDD}.log

echo_msg "LOGFILE used : ${LOGFILE}"
echo_msg "orahot backup for $ORACLE_SID started at `date`"

dbhome > /dev/null 2>&1

if [ $? != 0 ]; then
  echo_msg "Error: ${ORACLE_SID} is not a database instance on this server"
  exit 1
fi

ORAENV_ASK=NO
. oraenv > /dev/null 2>&1

if [ $? != 0 ]; then
  echo_msg "Error: Unable to set the environmment"
  exit 1
fi

#
# is the database open?
#

sqlplus -s /nolog << EOF > TEMP.txt
whenever sqlerror exit 1
connect / as sysdba
set head off
select status from v\$instance;

EOF

if [ $? != 0 ]; then
  echo_msg "Error: Unable to verify if the database is open"
  exit 1
fi

if [ "`grep OPEN TEMP.txt`" != "OPEN" ]; then
 echo_msg "Error: Database is not OPEN"
  exit 1
else
  echo_msg "Database verified as being OPEN"
fi

#
# verify the backup location
#

if [ -d ${BU_LOCATION} ]; then
  echo_msg "Confirmed BU_LOCATION ( ${BU_LOCATION} ) exists"
else
  echo_msg "Confirmed BU_LOCATION ( ${BU_LOCATION} ) does not exists. Cancelling the backup"
  exit 1
fi

mkdir ${BU_FILES_DIR} > /dev/null 2>&1
if [ $? != 0 ]; then
  echo_msg "Failed to create a good location for the hot backup - ${BU_FILES_DIR}"
  exit 1
else
  echo_msg "Create a good location for the hot backup - ${BU_FILES_DIR}"
fi


#
# Ensure database is running and is in ARCHIVELOG mode
#
sqlplus -s /nolog << EOF > TEMP.txt
WHENEVER SQLERROR EXIT 1
connect / as sysdba
set head off
select log_mode from v\$database where log_mode='ARCHIVELOG';

EOF

if [ $? != 0 ]; then
        echo "Error: Database not in Archive Mode"
        exit 1
fi

if [ "`grep ARCHIVELOG TEMP.txt`" != "ARCHIVELOG" ]; then
        echo "Error: Database is not in Archive Mode"
        exit 1
else
        echo "Database is in Archive Mode"
fi



#
# capture the current online log ---
#
sqlplus -s /nolog << EOF > TEMP.txt
WHENEVER SQLERROR EXIT 1
connect / as sysdba
set head off
select sequence# from v\$log where status='CURRENT'; 
EOF
START_SEQ=`grep -v '^$' TEMP.txt`
echo "Current Sequence Number is    ${START_SEQ}"


#
# is there another backup running already?
#
sqlplus -s /nolog << EOF > TEMP.txt
WHENEVER SQLERROR EXIT 1
connect / as sysdba
set head off
select * from v\$backup where status='ACTIVE';
EOF
if [ $? != 0 ]; then
	echo "Another backup is running"
	exit 1
else
        echo "No other backup is running"
fi


#
# cycle through the data files backing them up one at a time to $BU_FILES_DIR
#
echo_msg "Starting backup of datafiles....."

sqlplus -s /nolog << EOF > TEMP.txt
connect / as sysdba 
whenever sqlerror exit 1 
set pagesize 0 
set linesize 2048 
set heading off 
set feedback off 
set trimspool on
select tablespace_name ||' '||file_name||' '||' ${BU_FILES_DIR}/' ||        substr(file_name,               instr(file_name,'/',-1,1)+1,               length(file_name)              ) || '.' || file_id
from dba_data_files
order by 1;
EOF

if [ $? != 0 ]; then
	echo_msg "Error querying database."  
	exit
fi

echo "# Files: " > ${BU_FILES_DIR}/TEMP.txt
grep -v '^$' TEMP.txt | while read TBL DTF BUF;
do
	sqlplus -s /nolog << EOF > /dev/null
	whenever sqlerror exit 1
	connect / as sysdba
	alter tablespace ${TBL} begin backup;
	alter system switch logfile;
EOF
	echo "copying ${DTF} to ${BUF}"
	cp "${DTF}" "${BUF}"
	echo "copying ${DTF} ${BUF}" >> ${BU_FILES_DIR}/TEMP.txt
	echo "#recovering ${BUF} ${DTF}" >> ${BU_RECOVERY_FILES}
	echo_msg "Recovery file created: ${BU_RECOVERY_FILES}"

	sqlplus -s /nolog << EOF > /dev/null
	whenever sqlerror exit 1
	connect / as sysdba
	alter tablespace ${TBL} end backup;
EOF
	if [ $? != 0 ]; then
		echo_msg "Datafiles not backed up."
		exit 1
	else 	
		echo_msg "Datafiles backup completed."
	fi
done

#
# force log switch
#
sqlplus -s /nolog << EOF > /dev/null 2>&1
whenever sqlerror exit 1
connect / as sysdba
alter system switch logfile;
EOF

if [ $? != 0 ]; then
  echo_msg "Error: Unable to force log switch"
  exit 1
else
  echo_msg "Log switch forced"
fi

#
# capture the current online log ---
#
sqlplus -s /nolog << EOF > TEMP.txt
WHENEVER SQLERROR EXIT 1
connect / as sysdba
set head off
select sequence# from v\$log where status='CURRENT';
EOF
END_SEQ=`grep -v '^$' TEMP.txt`
echo "New Sequnce Number is    ${END_SEQ}"


#
# identify and copy all the archives to the $BU_FILES_DIR
#
echo_msg "Starting backup of archivelogs....."

sqlplus -s /nolog << EOF > TEMP.txt
connect / as sysdba
whenever sqlerror exit 1
set pagesize 0
set linesize 2048
set heading off
set feedback off
set trimspool on
select name||';'||'${BU_FILES_DIR}/'||substr(name, instr(name,'/',-1,1)+1, length(name)) from v\$archived_log where sequence# between ${START_SEQ} and ${END_SEQ};

EOF

if [ $? != 0 ]; then
        echo_msg "Archive log list not found."
        exit
fi
while read -r line; 
do
        archive=$(echo "$line" | cut -d ";" -f1)
        destination=$(echo "$line" | cut -d ";" -f2)
	echo "copying ${archive} to ${destination}"
        cp "$archive" "$destination"
	echo "recovering ${destination} ${archive}" >> ${BU_RECOVERY_FILES}
	echo_msg "Recovery file created: ${BU_RECOVERY_FILES}"

	if [ $? != 0 ]; then
                echo_msg "Archive logs not backed up."
                exit 1
        else
                echo_msg "Backup of archivelogs completed."
        fi

done < TEMP.txt

#
# Back up the control file (both binary and logical)
#
sqlplus -s /nolog << EOF > TEMP.txt
connect / as sysdba
whenever sqlerror exit 1
alter database backup controlfile to trace as '$BU_FILES_DIR/controlfile.trc' reuse;
alter database backup controlfile to '$BU_FILES_DIR/controlfile.bin';
exit;
EOF

if [ $? != 0 ]; then
        echo_msg "Control file backup failed."
	exit 1
else
	echo "Control file backed up successfully to $BU_FILES_DIR"
fi


echo_msg "orahot backup for $ORACLE_SID ended successfully at `date`"


